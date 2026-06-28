# Dev Infra Notes

一个轻量的个人技术知识库，先从远程开发、WSL、GPU 训练环境开始。

这个仓库的设计原则：

- 先写有用的内容，不追求一开始就完美分类。
- 所有文章用 Markdown 保存，方便 Git 管理、审阅和回滚。
- 用 MkDocs Material 发布为静态网站，方便在线访问和搜索。
- 保留公开的 Markdown 源文件，方便人和 AI 阅读。

## 本地预览

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
mkdocs serve
```

打开：

```text
http://127.0.0.1:8000
```

## 新增文章

把 Markdown 放到 `docs/` 下，然后在 `mkdocs.yml` 的 `nav` 中加一行。

例如：

```yaml
nav:
  - 首页: index.md
  - 远程开发:
      - Mac 远程使用 WSL: remote-dev/mac-to-wsl-remote-dev.md
```

## 发布到 GitHub Pages

1. 在 GitHub 创建一个空仓库，例如 `dev-infra-notes`。
2. 推送本仓库到 GitHub。
3. 在仓库设置里启用 Pages，选择从 `gh-pages` 分支发布。
4. 修改 `mkdocs.yml` 里的 `site_url` 为你的真实站点地址。
5. 每次推送到 `main` 后，GitHub Actions 会自动构建并发布。

