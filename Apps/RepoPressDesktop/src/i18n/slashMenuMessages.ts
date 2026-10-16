import { writingBuiltinSnippetMessages } from "./writingBuiltinSnippetMessages";

/** Presentation labels for the slash menu; command data and callbacks stay untouched. */
const slashCoreMessages: Record<string, string> = {
  "斜杠命令": "Slash commands",
  "插入块": "Insert block",
  "没有匹配的命令": "No matching commands",
  "插入一段正文": "Insert a paragraph",
  "一级标题": "Heading 1",
  "插入 H1 标题": "Insert an H1 heading",
  "二级标题": "Heading 2",
  "插入 H2 标题": "Insert an H2 heading",
  "三级标题": "Heading 3",
  "插入 H3 标题": "Insert an H3 heading",
  "插入引用块": "Insert a blockquote",
  "插入无序列表": "Insert a bulleted list",
  "插入有序列表": "Insert a numbered list",
  "插入待办事项": "Insert a task list",
  "插入 fenced code block": "Insert a fenced code block",
  "表格": "Table",
  "插入两列表格": "Insert a two-column table",
  "图片占位": "Image placeholder",
  "插入图片占位语法": "Insert image placeholder syntax",
  "脚注": "Footnote",
  "插入脚注引用与定义": "Insert a footnote reference and definition",
  "插入分隔线": "Insert a divider",
};

export const slashMenuMessages: Record<string, string> = Object.assign({}, slashCoreMessages, writingBuiltinSnippetMessages);
