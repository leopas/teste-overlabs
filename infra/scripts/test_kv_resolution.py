#!/usr/bin/env python3
"""Script para testar resolução de Key Vault reference no container."""

import os
import sys

key = os.getenv('OPENAI_API_KEY', 'NOT_SET')

print(f'OPENAI_API_KEY value preview: {key[:30] if key != "NOT_SET" and len(key) > 30 else key}...')
print(f'Length: {len(key) if key != "NOT_SET" else 0}')

if key.startswith('@Microsoft.KeyVault'):
    print('[ERRO] Key Vault reference NAO foi resolvida pelo Azure!')
    print('[INFO] A referencia ainda esta no formato: @Microsoft.KeyVault(...)')
    print('[POSSIVEIS CAUSAS]:')
    print('  1. Managed Identity nao tem permissoes no Key Vault')
    print('  2. Key Vault reference esta malformada')
    print('  3. Container App precisa ser reiniciado')
    sys.exit(1)
elif key == 'NOT_SET':
    print('[ERRO] OPENAI_API_KEY nao esta definida!')
    sys.exit(1)
elif len(key) < 10:
    print('[ERRO] OPENAI_API_KEY parece estar vazia ou invalida!')
    sys.exit(1)
elif not key.startswith('sk-'):
    print('[AVISO] OPENAI_API_KEY nao comeca com "sk-"')
    print('[INFO] Pode estar resolvida mas com valor incorreto')
    sys.exit(1)
else:
    print('[OK] OPENAI_API_KEY parece estar resolvida corretamente!')
    print('[OK] Key Vault reference foi resolvida pelo Azure')
    sys.exit(0)
