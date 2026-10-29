# -*- coding: utf-8 -*-
"""UserPromptSubmit 钩子（可选组件）：把当前日期时间 + 星期 + 市场时段注入对话上下文。

stdout 输出 JSON：{"additionalContext": "..."}；宿主会把它追加进对话上下文，
让 agent 以真实时间为准（禁止凭记忆猜日期），交易类回答先核对市场时段。
市场时段默认按 A 股；不需要可删掉 market 段，或安装时不选本组件。
"""
import json, sys
try:
    sys.stdout.reconfigure(encoding="utf-8")
    import datetime
    now = datetime.datetime.now()
    wd = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][now.weekday()]
    market = ""
    t = now.hour * 60 + now.minute
    if now.weekday() < 5:
        if t < 9 * 60 + 15:
            market = " | A股盘前"
        elif t < 9 * 60 + 25:
            market = " | A股集合竞价中(9:15-9:25)"
        elif t < 11 * 60 + 30:
            market = " | A股盘中(上午)"
        elif t < 13 * 60:
            market = " | A股午间休市"
        elif t < 15 * 60:
            market = " | A股盘中(下午)"
        else:
            market = " | A股已收盘"
    else:
        market = " | 周末休市"
    ctx = "[系统时间钩子] 当前时间: %s %s%s。回答前以此时间为准，禁止凭记忆猜测日期；交易类回答必须先核对此时间与市场时段。" % (
        now.strftime("%Y-%m-%d %H:%M:%S"), wd, market)
    print(json.dumps({"additionalContext": ctx}, ensure_ascii=False))
except Exception as e:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        print(json.dumps({"additionalContext": "[系统时间钩子] 时间获取失败: %s" % e}, ensure_ascii=False))
    except Exception:
        pass
sys.exit(0)
