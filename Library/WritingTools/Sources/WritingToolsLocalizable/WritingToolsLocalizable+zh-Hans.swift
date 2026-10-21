//
//  WritingToolsLocalizable+zh-Hans.swift
//
//
//  Created by 秋星桥 on 2024/8/16.
//

import Foundation

extension WritingToolsLocalizable {
    func setupChineseSimplified() {
        localizedStringContents["zh-Hans".lowercased()] = [
            "Faircopy": "清稿",

            "%d character": "%d 字",
            "%d characters": "%d 字",

            "Available Models": "可用模型列表",
            "Proofread": "校对",
            "Rewrite": "重写",

            "Friendly": "友好",
            "Professional": "专业",
            "Concise": "简洁",

            "Translate": "翻译",
            "Expand": "扩写",
            "Summarize": "总结",
            "Segment": "分词",
            "%d words": "%d 词",
            "%d selected": "已选 %d",

            /* 3.0.49: 分词全选（状态行的胶囊按钮 + 全选时的计数替代文案） */
            "Select All": "全选",
            "Deselect All": "取消全选",
            "All": "全部",

            "First %d chars": "仅前 %d 字",
            "Custom": "自定义",
            "Manage Custom Prompts": "管理自定义提示词",

            /* 3.0.48: 面板模式全部隐藏时的空态提示（可在设置→写作面板模式里重新启用） */
            "All panel modes are hidden. Turn some back on in Settings.": "所有面板模式均已隐藏，可在设置中重新启用。",

            "Discard": "丢弃",
            "Again": "重试",
            "Accept": "接受",
            "Copy": "复制",
            "Copy in Source Order": "按原文顺序复制",
            "Copy in Selection Order": "按选择顺序复制",
            "Order: Source": "顺序：原文",
            "Order: Selection": "顺序：选择",
            "Share": "分享",
            "Cancel": "取消",

            "Search in Apps": "在应用中搜索",

            "Ask": "提问",
            "Type your question": "输入你的问题",

            /* 3.0.50: 提问弹窗的第二个提交按钮——允许超出源文本 / 联网作答 */
            "Ask with Web": "联网提问",

            /* 3.0.51: 多轮追问（回答页按钮改成菜单 + 轮次提示） */
            "Follow Up": "追问",
            "Follow Up with Web": "联网追问",
            "Ask Again": "重新提问",
            "Turn %d": "第 %d 轮",

            /* 3.0.52: 回答里的链接区块（联网检索返回的引用，或正文里的 URL） */
            "References": "参考链接",

            /* 3.0.53: 联网授权改为会话级——弹窗标题显示当前状态，次按钮显式切换 */
            "Web": "联网",
            "With Web": "联网",
            "Without Web": "不联网",
            "No link found — search the web": "没有给出链接 · 联网重问",
            "Search in Browser": "浏览器搜索",
            "This endpoint has no web search": "当前上游没有联网检索",

            "Insert into Prompt": "塞进提示词",

            "Back": "返回",

            "Made with ♥ by OwnGoal Studio": "「乌龙工作室」倾情献制",

            "Unable to establish a secure connection to daemon": "无法建立与服务的安全连接",
        ]
    }
}
