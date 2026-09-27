#!/usr/bin/env python3
"""发送飞书消息到用户的 Home 频道。用法: notify-feishu.py "消息内容" """
import json
import os
import sys
import urllib.request
from pathlib import Path

ENV = Path(os.environ.get("HERMES_ENV", Path.home() / ".hermes" / ".env"))


def load_env():
    cfg = {}
    try:
        for line in ENV.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return cfg


def get_token(app_id, app_secret):
    req = urllib.request.Request(
        'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
        data=json.dumps({'app_id': app_id, 'app_secret': app_secret}).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r).get('tenant_access_token')


def send(token, chat_id, text):
    req = urllib.request.Request(
        'https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id',
        data=json.dumps({
            'receive_id': chat_id,
            'msg_type': 'text',
            'content': json.dumps({'text': text}, ensure_ascii=False)}).encode(),
        headers={'Content-Type': 'application/json',
                 'Authorization': f'Bearer {token}'})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main():
    if len(sys.argv) < 2:
        print('用法: notify-feishu.py "消息"', file=sys.stderr)
        return 2
    msg = sys.argv[1]
    if not msg.strip():
        return 0

    cfg = load_env()
    app_id = cfg.get('FEISHU_APP_ID')
    app_secret = cfg.get('FEISHU_APP_SECRET')
    chat_id = cfg.get('FEISHU_HOME_CHANNEL')
    if not all([app_id, app_secret, chat_id]):
        print('缺少飞书配置', file=sys.stderr)
        return 1

    try:
        token = get_token(app_id, app_secret)
        resp = send(token, chat_id, msg)
        if resp.get('code') == 0:
            return 0
        print(f"发送失败: {resp}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f'发送异常: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
