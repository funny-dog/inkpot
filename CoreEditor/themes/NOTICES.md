# 内置主题与许可

Inkpot 将下列 MIT 主题的配色、字体栈、标题比例、行距和基础组件样式适配到 CodeMirror 6。未打包原主题字体、图标、背景图片、动画或网络资源。主题名称用于标明来源，不代表原作者为 Inkpot 背书。未单独映射的语法类别沿用 Inkpot 现有代码配色。

## 适配说明

- 主题设置默认字体、标题层级、行距、正文宽度及引用、表格等样式；手动选择的字体和字号优先，主题不改变文件内容或编辑行为。源码模式保持等宽显示。
- 不随应用分发第三方字体文件；优先使用已安装的原主题字体，缺少时使用系统同类字体。macOS 上 Lapis 中文使用宋体，Phycat 中文使用楷体，Ursine 正文使用 Avenir Next、标题使用 Georgia／宋体。其他平台按 CSS 字体栈回退。
- 适配保留原主题的主要排版特征，不保证与 Typora 逐像素相同。标题的垂直留白使用 padding，避免 CodeMirror 的行高、光标定位与滚动测量出错；导出沿用 Inkpot 固定浅色排版。
- 主要背景、正文、标题和强调色取自下列固定版本；部分透明色映射为不透明色，引用、表格和查找栏按现有组件映射相关色。
- 为保证可读性，Ursine/Pie 浅色链接、Phycat 浅色标题与链接使用较深色；Notion 行内代码红色、Dracula 次要文字与注释色、部分其他次要文字作对比度调整。
- Ursine 的原始配色受到 Bear Red Graphite/Dark Graphite 启发，代码配色引用 CodeMirror 3024 Day（Jan T. Sott；Base16 原配色 Chris Kempson）和 Dracula（Michael Kaminsky；原配色 Zeno Rocha）。
- Lapis 原样式基于 evgo2017/typora-theme-orange-heart，代码配色受 Winter is Coming 启发。此适配的未映射代码配色沿用 Inkpot。
- Pie 原主题声明受到少数派和 etigerstudio/typora-misty-theme 启发，原始代码配色使用 CodeMirror material-palenight；此适配的代码配色沿用 Inkpot。

## 上游许可原文

### Lapis

- 来源：https://github.com/YiNNx/typora-theme-lapis
- 固定版本：`9124f8659699691edccdc52ba710c79aa801c621`
- 配色参考文件：lapis.css、lapis-dark.css
- 许可证：https://github.com/YiNNx/typora-theme-lapis/blob/9124f8659699691edccdc52ba710c79aa801c621/LICENSE

```text
MIT License

Copyright (c) 2024 YiNN

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Ursine

- 来源：https://github.com/noatpad/typora-theme-ursine
- 固定版本：`de3c1d696e4353f6549ab3dfc7718d1cd8c92e0c`
- 配色参考文件：ursine-polar.scss、ursine-umbra.scss、ursine/_code-3024-day.scss、ursine/_code-dracula.scss
- 许可证：https://github.com/noatpad/typora-theme-ursine/blob/de3c1d696e4353f6549ab3dfc7718d1cd8c92e0c/LICENSE

```text
MIT License

Copyright (c) 2019 Daniel Hernandez

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Notion

- 来源：https://github.com/adrian-fuertes/typora-notion-theme
- 固定版本：`2611026951d7dacc3e5af21c6c09d076d17793de`
- 配色参考文件：themes/classic/notion-light-classic.css、themes/classic/notion-dark-classic.css
- 许可证：https://github.com/adrian-fuertes/typora-notion-theme/blob/2611026951d7dacc3e5af21c6c09d076d17793de/LICENSE

```text
MIT License

Copyright (c) 2022 adrian-fuertes

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Pie

- 来源：https://github.com/kevinzhao2233/typora-theme-pie
- 固定版本：`7b1141f77f6e87850dfad676fc9f07d44ec5cea8`
- 配色参考文件：pie.css、pie-dark.css
- 许可证：https://github.com/kevinzhao2233/typora-theme-pie/blob/7b1141f77f6e87850dfad676fc9f07d44ec5cea8/LICENSE

```text
MIT License

Copyright (c) 2020 KevinZhao

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Drake

- 来源：https://github.com/liangjingkanji/DrakeTyporaTheme
- 固定版本：`771df28080610cf6b0bd5f6f0c1864efa2d9a41e`
- 配色参考文件：drake-light.css、drake-dark.css
- 许可证：https://github.com/liangjingkanji/DrakeTyporaTheme/blob/771df28080610cf6b0bd5f6f0c1864efa2d9a41e/LICENSE

```text
MIT License

Copyright (c) 2023 劉強東

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

样式文件同时保留的版权标识：`Copyright (c) 2023 劉強東 https://github.com/liangjingkanji`。

### Phycat

- 来源：https://github.com/sumruler/typora-theme-phycat
- 固定版本：`b49f1fc6b193e333a3ebb186bbf1ae7f8fc21778`
- 配色参考文件：phycat-forest.css、phycat-abyss.css
- 许可证：https://github.com/sumruler/typora-theme-phycat/blob/b49f1fc6b193e333a3ebb186bbf1ae7f8fc21778/LICENSE

```text
MIT License

Copyright (c) [2024] [徐继龙]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Dracula

- 来源：https://github.com/dracula/typora
- 固定版本：`61a9edea74b2c25de27b0a720194c7ebdd147b0c`
- 配色参考文件：dracula.css、dracula/codeblock.dark.css
- 许可证：https://github.com/dracula/typora/blob/61a9edea74b2c25de27b0a720194c7ebdd147b0c/LICENSE

```text
MIT License

Copyright (c) 2019 Gustavo Pereira

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
