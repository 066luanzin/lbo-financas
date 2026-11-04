"""Gera o altstore.json (fonte do AltStore) pra versão que acabou de ser compilada.

Uso: python3 scripts/fonte_altstore.py <versao> <build> <tag> <tamanho_bytes> <notas>
"""
import json
import sys
from datetime import datetime, timezone

versao, build, tag, tamanho, notas = sys.argv[1:6]
repo = "066luanzin/lbo-financas"
download = f"https://github.com/{repo}/releases/download/{tag}/LBO-Financas.ipa"
icone = f"https://raw.githubusercontent.com/{repo}/main/TheBox/Assets.xcassets/AppIcon.appiconset/icon.png"
data = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

privacidade = {
    "NSFaceIDUsageDescription": "Usamos o Face ID para proteger seus dados financeiros.",
}

fonte = {
    "name": "LBO Finanças",
    "identifier": "com.lbofinancas.fonte",
    "subtitle": "Apps do Luan",
    "sourceURL": f"https://github.com/{repo}/releases/latest/download/altstore.json",
    "iconURL": icone,
    "tintColor": "2F6BFF",
    "apps": [{
        "name": "LBO Finanças",
        "bundleIdentifier": "com.lbofinancas.app",
        "developerName": "Luan",
        "subtitle": "Suas finanças em ordem",
        "localizedDescription": "Controle de gastos, receitas, contas, cartões e orçamento.",
        "iconURL": icone,
        "tintColor": "2F6BFF",
        "category": "utilities",
        "screenshotURLs": [],
        "versions": [{
            "version": versao,
            "buildVersion": build,
            "date": data,
            "localizedDescription": notas,
            "downloadURL": download,
            "size": int(tamanho),
            "minOSVersion": "17.0",
        }],
        "version": versao,
        "versionDate": data,
        "versionDescription": notas,
        "downloadURL": download,
        "size": int(tamanho),
        "appPermissions": {"entitlements": [], "privacy": privacidade},
    }],
    "news": [],
}
print(json.dumps(fonte, ensure_ascii=False, indent=2))
