# Decisiones

Ledger **solo-agregar**. Una entrada por decisión; se anula agregando otra con `reemplaza-a: D-MMM` y poniendo `estado: reemplazada por D-NNN` en la vieja. Las entradas con `origen: ficha de commit` las vuelca dev-bridge/bin/aprendizaje-fichas.py desde los commits.

### D-001 — CI identity via env vars and no pull_request trigger on the self-hosted runner

- fecha: 2026-09-18
- fase: —
- estado: vigente
- origen: ficha de commit (aprendizaje P0)
- commit: 357fbd6
- texto: Por qué esto y no <alternativa>: moving CI back to hosted runners — hosted minutes are exhausted. Riesgo: PRs get no CI; fine because PRs are disabled on the repo
- concepto: self-hosted-runner-public-repo
- evidencia: commit 357fbd6 en silent-pass
