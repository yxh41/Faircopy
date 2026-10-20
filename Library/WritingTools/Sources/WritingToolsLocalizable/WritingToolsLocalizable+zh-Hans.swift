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
            "Insert into Prompt": "塞进提示词",

            "Back": "返回",

            "Made with ♥ by OwnGoal Studio": "「乌龙工作室」倾情献制",

            "Unable to establish a secure connection to daemon": "无法建立与服务的安全连接",
        ]
    }
}
