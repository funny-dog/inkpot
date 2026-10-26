using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace Inkpot;

internal static class PreferencesDialog
{
    // 代码创建的对话框须显式套用 WinUI 默认样式，否则按钮区与圆角不是当前 Fluent 外观。
    internal static Style DialogStyle => (Style)Application.Current.Resources["DefaultContentDialogStyle"];

    internal static async Task<AppPreferences?> ShowAsync(XamlRoot root, AppPreferences current)
    {
        AppPreferences? acceptedResult = null;
        var dialog = Create(root, current, prefs => acceptedResult = prefs);
        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary ? acceptedResult : null;
    }

    internal static ContentDialog Create(XamlRoot root, AppPreferences current, Action<AppPreferences> accepted)
    {
        var draft = current.Normalize();

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Style = DialogStyle,
            RequestedTheme = root.Content is FrameworkElement element ? element.ActualTheme : ElementTheme.Default,
            Title = L10n.Text("Preferences"),
            PrimaryButtonText = L10n.Text("Save"),
            CloseButtonText = L10n.Text("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };

        var appearanceCombo = new ComboBox { MinWidth = 200 };
        var systemItem = new ComboBoxItem { Content = L10n.Text("AppearanceSystem"), Tag = "system" };
        var lightItem = new ComboBoxItem { Content = L10n.Text("AppearanceLight"), Tag = "light" };
        var darkItem = new ComboBoxItem { Content = L10n.Text("AppearanceDark"), Tag = "dark" };
        appearanceCombo.Items.Add(systemItem);
        appearanceCombo.Items.Add(lightItem);
        appearanceCombo.Items.Add(darkItem);
        appearanceCombo.SelectedItem = draft.Appearance switch
        {
            "light" => lightItem,
            "dark" => darkItem,
            _ => systemItem,
        };

        var bodyFamilyCombo = new ComboBox { IsEditable = true, MinWidth = 200 };
        var bodyDefaultItem = new ComboBoxItem { Content = L10n.Text("DefaultFont"), Tag = "" };
        bodyFamilyCombo.Items.Add(bodyDefaultItem);
        string[] commonBodyFonts = ["Segoe UI", "Microsoft YaHei UI", "Arial", "Calibri", "Times New Roman", "Georgia"];
        foreach (var font in commonBodyFonts)
        {
            bodyFamilyCombo.Items.Add(new ComboBoxItem { Content = font, Tag = font });
        }
        if (string.IsNullOrEmpty(draft.BodyFamily))
        {
            bodyFamilyCombo.SelectedItem = bodyDefaultItem;
        }
        else
        {
            var found = bodyFamilyCombo.Items
                .OfType<ComboBoxItem>()
                .FirstOrDefault(item => string.Equals((string)item.Tag, draft.BodyFamily, StringComparison.OrdinalIgnoreCase));
            if (found is not null)
            {
                bodyFamilyCombo.SelectedItem = found;
            }
            else
            {
                bodyFamilyCombo.Text = draft.BodyFamily;
            }
        }

        var bodySizeBox = SizeBox(draft.BodySize);

        var codeFamilyCombo = new ComboBox { IsEditable = true, MinWidth = 200 };
        string[] commonCodeFonts = ["Consolas", "Cascadia Code", "Courier New", "Lucida Console", "Fira Code", "JetBrains Mono"];
        foreach (var font in commonCodeFonts)
        {
            codeFamilyCombo.Items.Add(new ComboBoxItem { Content = font, Tag = font });
        }
        var foundCode = codeFamilyCombo.Items
            .OfType<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals((string)item.Tag, draft.CodeFamily, StringComparison.OrdinalIgnoreCase));
        if (foundCode is not null)
        {
            codeFamilyCombo.SelectedItem = foundCode;
        }
        else
        {
            codeFamilyCombo.Text = draft.CodeFamily;
        }

        var codeSizeBox = SizeBox(draft.CodeSize);

        var defaultSourceSwitch = Switch(draft.DefaultSourceMode);

        var indentCombo = new ComboBox { MinWidth = 120 };
        var indent2 = new ComboBoxItem { Content = string.Format(L10n.Text("SpacesFormat"), 2), Tag = 2 };
        var indent4 = new ComboBoxItem { Content = string.Format(L10n.Text("SpacesFormat"), 4), Tag = 4 };
        indentCombo.Items.Add(indent2);
        indentCombo.Items.Add(indent4);
        indentCombo.SelectedItem = draft.IndentWidth == 4 ? indent4 : indent2;

        var pairBracketsSwitch = Switch(draft.PairBrackets);
        var pairMarkdownSwitch = Switch(draft.PairMarkdown);
        var focusModeSwitch = Switch(draft.FocusMode);
        var typewriterModeSwitch = Switch(draft.TypewriterMode);

        // 与 macOS 设置窗口相同的分组：每组一个标题和一张卡片，卡片内每行左侧说明、右侧控件。
        var panel = new StackPanel
        {
            Spacing = 4,
            MinWidth = 420,
            Margin = new Thickness(0, 4, 12, 8),
        };
        panel.Children.Add(Card(Row("Appearance", appearanceCombo)));
        AddSection(panel, "FontSection",
            Row("BodyFont", bodyFamilyCombo), Row("BodyFontSize", bodySizeBox),
            Row("CodeFont", codeFamilyCombo), Row("CodeFontSize", codeSizeBox));
        AddSection(panel, "EditingSection", Row("DefaultSourceMode", defaultSourceSwitch), Row("IndentWidth", indentCombo));
        AddSection(panel, "PairingSection", Row("PairBrackets", pairBracketsSwitch), Row("PairMarkdown", pairMarkdownSwitch));
        AddSection(panel, "DisplayModesSection", Row("FocusMode", focusModeSwitch), Row("TypewriterMode", typewriterModeSwitch));

        var scrollViewer = new ScrollViewer
        {
            Content = panel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            MaxHeight = 520,
        };

        dialog.Content = scrollViewer;

        dialog.PrimaryButtonClick += (_, _) =>
        {
            string appearance = (appearanceCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "system";

            // 编辑后的文字可能尚未提交为 SelectedItem，优先使用输入框中的实际值。
            string bodyFamily = ReadFont(bodyFamilyCombo, "");
            string codeFamily = ReadFont(codeFamilyCombo, "Consolas");

            int indent = (indentCombo.SelectedItem as ComboBoxItem)?.Tag as int? ?? 2;

            var result = (current with
            {
                Appearance = appearance,
                BodyFamily = bodyFamily,
                BodySize = bodySizeBox.Value,
                CodeFamily = codeFamily,
                CodeSize = codeSizeBox.Value,
                DefaultSourceMode = defaultSourceSwitch.IsOn,
                IndentWidth = indent,
                PairBrackets = pairBracketsSwitch.IsOn,
                PairMarkdown = pairMarkdownSwitch.IsOn,
                FocusMode = focusModeSwitch.IsOn,
                TypewriterMode = typewriterModeSwitch.IsOn,
            }).Normalize();

            accepted(result);
        };

        return dialog;
    }

    private static NumberBox SizeBox(double value) => new()
    {
        Value = value,
        Minimum = 8,
        Maximum = 72,
        SmallChange = 1,
        LargeChange = 2,
        MinWidth = 120,
        SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
    };

    // 开关放在行尾，不显示“开／关”文字，状态由开关本身表达。
    private static ToggleSwitch Switch(bool isOn) => new() { IsOn = isOn, OnContent = "", OffContent = "", MinWidth = 0 };

    private static Grid Row(string key, FrameworkElement control)
    {
        var row = new Grid { MinHeight = 48, ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new TextBlock { Text = L10n.Text(key), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        control.VerticalAlignment = VerticalAlignment.Center;
        control.HorizontalAlignment = HorizontalAlignment.Right;
        // 控件没有自带标题，读屏名称取自本行说明文字。
        AutomationProperties.SetName(control, label.Text);
        Grid.SetColumn(control, 1);
        row.Children.Add(label);
        row.Children.Add(control);
        return row;
    }

    private static Border Card(params Grid[] rows)
    {
        var stack = new StackPanel();
        for (int index = 0; index < rows.Length; index++)
        {
            if (index > 0) stack.Children.Add(new Rectangle { Style = (Style)Application.Current.Resources["InkpotSettingsDividerStyle"] });
            stack.Children.Add(rows[index]);
        }
        return new Border { Style = (Style)Application.Current.Resources["InkpotSettingsCardStyle"], Child = stack };
    }

    private static void AddSection(StackPanel panel, string titleKey, params Grid[] rows)
    {
        panel.Children.Add(new TextBlock
        {
            Text = L10n.Text(titleKey),
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            Margin = new Thickness(2, 16, 0, 4),
        });
        panel.Children.Add(Card(rows));
    }

    private static string ReadFont(ComboBox combo, string fallback)
    {
        string text = combo.Text.Trim();
        if (combo.SelectedItem is ComboBoxItem selected && text == selected.Content?.ToString()) return (string)selected.Tag;
        return string.IsNullOrEmpty(text) || text == L10n.Text("DefaultFont") ? fallback : text;
    }
}
