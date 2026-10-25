using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Inkpot;

internal static class PreferencesDialog
{
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
            RequestedTheme = root.Content is FrameworkElement element ? element.ActualTheme : ElementTheme.Default,
            Title = L10n.Text("Preferences"),
            PrimaryButtonText = L10n.Text("Save"),
            CloseButtonText = L10n.Text("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };

        var panel = new StackPanel
        {
            Spacing = 16,
            MinWidth = 360,
            Margin = new Thickness(0, 8, 12, 8),
        };

        var appearanceCombo = new ComboBox
        {
            Header = L10n.Text("Appearance"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
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
        panel.Children.Add(appearanceCombo);

        var fontSectionHeader = new TextBlock
        {
            Text = L10n.Text("FontSection"),
            Margin = new Thickness(0, 8, 0, 0),
        };
        panel.Children.Add(fontSectionHeader);

        var bodyFamilyCombo = new ComboBox
        {
            Header = L10n.Text("BodyFont"),
            IsEditable = true,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
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
        panel.Children.Add(bodyFamilyCombo);

        var bodySizeBox = new NumberBox
        {
            Header = L10n.Text("BodyFontSize"),
            Value = draft.BodySize,
            Minimum = 8,
            Maximum = 72,
            SmallChange = 1,
            LargeChange = 2,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(bodySizeBox);

        var codeFamilyCombo = new ComboBox
        {
            Header = L10n.Text("CodeFont"),
            IsEditable = true,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
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
        panel.Children.Add(codeFamilyCombo);

        var codeSizeBox = new NumberBox
        {
            Header = L10n.Text("CodeFontSize"),
            Value = draft.CodeSize,
            Minimum = 8,
            Maximum = 72,
            SmallChange = 1,
            LargeChange = 2,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(codeSizeBox);

        var editingSectionHeader = new TextBlock
        {
            Text = L10n.Text("EditingSection"),
            Margin = new Thickness(0, 8, 0, 0),
        };
        panel.Children.Add(editingSectionHeader);

        var defaultSourceSwitch = new ToggleSwitch
        {
            Header = L10n.Text("DefaultSourceMode"),
            IsOn = draft.DefaultSourceMode,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(defaultSourceSwitch);

        var indentCombo = new ComboBox
        {
            Header = L10n.Text("IndentWidth"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var indent2 = new ComboBoxItem { Content = string.Format(L10n.Text("SpacesFormat"), 2), Tag = 2 };
        var indent4 = new ComboBoxItem { Content = string.Format(L10n.Text("SpacesFormat"), 4), Tag = 4 };
        indentCombo.Items.Add(indent2);
        indentCombo.Items.Add(indent4);
        indentCombo.SelectedItem = draft.IndentWidth == 4 ? indent4 : indent2;
        panel.Children.Add(indentCombo);

        var pairBracketsSwitch = new ToggleSwitch
        {
            Header = L10n.Text("PairBrackets"),
            IsOn = draft.PairBrackets,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(pairBracketsSwitch);

        var pairMarkdownSwitch = new ToggleSwitch
        {
            Header = L10n.Text("PairMarkdown"),
            IsOn = draft.PairMarkdown,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(pairMarkdownSwitch);

        var displaySectionHeader = new TextBlock
        {
            Text = L10n.Text("DisplayModesSection"),
            Margin = new Thickness(0, 8, 0, 0),
        };
        panel.Children.Add(displaySectionHeader);

        var focusModeSwitch = new ToggleSwitch
        {
            Header = L10n.Text("FocusMode"),
            IsOn = draft.FocusMode,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(focusModeSwitch);

        var typewriterModeSwitch = new ToggleSwitch
        {
            Header = L10n.Text("TypewriterMode"),
            IsOn = draft.TypewriterMode,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(typewriterModeSwitch);

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

    private static string ReadFont(ComboBox combo, string fallback)
    {
        string text = combo.Text.Trim();
        if (combo.SelectedItem is ComboBoxItem selected && text == selected.Content?.ToString()) return (string)selected.Tag;
        return string.IsNullOrEmpty(text) || text == L10n.Text("DefaultFont") ? fallback : text;
    }
}
