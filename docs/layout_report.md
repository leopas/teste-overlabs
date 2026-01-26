## Relatório de layout (gerado)
- Gerado em: `2026-01-26T14:54:50.578185+00:00`
- DOCS_ROOT: `/docs`
- Total de arquivos: **14**

### Distribuição por extensão
- **.txt**: 14

### Top 50 por tamanho
- `funcionarios.txt` — 895 bytes — `utf-8` — 2026-01-26T13:12:30.682858
- `politica_reembolso_v3.txt` — 228 bytes — `utf-8` — 2026-01-26T13:12:30.666827
- `manual_financeiro.txt` — 220 bytes — `utf-8` — 2026-01-26T13:12:30.669830
- `politica_reembolso_v1.txt` — 185 bytes — `utf-8` — 2026-01-26T13:12:30.690293
- `politica_seguranca.txt` — 151 bytes — `utf-8` — 2026-01-26T13:12:30.700372
- `faq_reembolso_antigo.txt` — 122 bytes — `utf-8` — 2026-01-26T13:12:30.710788
- `politica_viagem.txt` — 115 bytes — `utf-8` — 2026-01-26T13:12:30.707858
- `ata_reuniao.txt` — 100 bytes — `utf-8` — 2026-01-26T13:12:30.698364
- `politica_privacidade.txt` — 78 bytes — `utf-8` — 2026-01-26T13:12:30.687293
- `politica_beneficios.txt` — 64 bytes — `utf-8` — 2026-01-26T13:12:30.678854
- `comunicado_2021.txt` — 62 bytes — `utf-8` — 2026-01-26T13:12:30.719701
- `manual_operacional.txt` — 60 bytes — `utf-8` — 2026-01-26T13:12:30.713299
- `procedimento_aprovacao.txt` — 59 bytes — `utf-8` — 2026-01-26T13:12:30.651667
- `orientacao_geral.txt` — 49 bytes — `utf-8` — 2026-01-26T13:12:30.692361

### Classificação de layouts
- **L1_POLICY**: 13
- **L2_FAQ**: 1

### Padrões detectados (com exemplos)

#### `funcionarios.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': True, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Nome: João Silva
Cargo: Analista Financeiro
Departamento: Financeiro
Cidade: São Paulo
Gestor: Maria Oliveira
CPF: 123.456.789-00
--------------------------------------------------
Nome: Maria Oliveira
Cargo: Gerente Financeira
Departamento: Financeiro
```

#### `politica_reembolso_v3.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Política de Reembolso – Versão 3.0
Data: 05/12/2025
O prazo para reembolso de despesas nacionais é de até 10 dias corridos.
O prazo para reembolso de despesas internacionais é de até 30 dias corridos, após aprovação.
```

#### `manual_financeiro.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Manual Financeiro Interno
Atualizado em: 01/02/2024
As despesas internacionais seguem regras específicas definidas na Política de Reembolso vigente.
Em caso de conflito, a política mais recente deve ser considerada.
```

#### `politica_reembolso_v1.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Política de Reembolso – Versão 1.0
Data: 10/01/2022
O prazo para reembolso de despesas nacionais e internacionais é de até 15 dias corridos após a aprovação da solicitação.
```

#### `politica_seguranca.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Política de Segurança da Informação
É proibido divulgar dados pessoais de funcionários, incluindo CPF, endereço, dados bancários ou salário.
```

#### `faq_reembolso_antigo.txt`
- layout: **L2_FAQ**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': True, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Pergunta: Qual o prazo de reembolso?
Resposta: O prazo padrão de reembolso é de 15 dias para qualquer tipo de despesa.
```

#### `politica_viagem.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Política de Viagens Corporativas
A empresa recomenda a compra de passagens com antecedência mínima de 14 dias.
```

#### `ata_reuniao.txt`
- layout: **L1_POLICY**
- padrões: `{'md_headings': False, 'upper_headings': False, 'separators': False, 'qa_blocks': False, 'numbered_steps': 0, 'bullet_lists': 0, 'pipe_table': False}`

Exemplo (até 10 linhas):
```
Foi discutida a possibilidade de revisão do prazo de reembolso.
Nenhuma decisão final foi tomada.
```

### Recomendações de chunking (R1)
- **Target**: ~650 tokens por chunk (aprox. 2600 chars) com **overlap** ~120 tokens.
- **Split primário**: headings (`#`), caixa alta, separadores `====`/`----`.
- **FAQ (L2)**: manter pares Pergunta/Resposta no mesmo chunk.
- **Procedimento (L3)**: agrupar passos sequenciais; evitar quebrar no meio de uma sequência.
- **Tabela textual (L4)**: chunk por blocos (linhas) preservando header quando existir.
