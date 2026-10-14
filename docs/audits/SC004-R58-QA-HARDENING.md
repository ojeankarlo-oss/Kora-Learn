# SC004 R5.8 — QA hardening

Base obrigatória: `711f761073253c4d0f010f35f75606a31ab075aa`.
Branch: `feature/sc004-r58-qa-hardening`.
Worktree: `C:/projeto/Kora-Learn/.worktrees/sc004-r58`.
Main verificada no pre-flight: `e84ea018b4bd1be092ea60917c0f0c6ce3a4f618`.

Veredito desta entrega: **BLOCKED**. PostgreSQL, Docker e Podman não foram encontrados no PATH nem nas instalações padrão inspecionadas. WSL informou que não está instalado. Nenhum PASS de runtime, KILLED ou SURVIVED foi obtido nesta máquina. A validação estática não substitui PostgreSQL nem auditoria independente.

## Correções

| Achado | Alteração de QA |
| --- | --- |
| G2 | UUID do ator de R57-COUNT-NULL corrigido. O autoteste exige `STATE_NULL`, SQLSTATE vazio e a identidade owner-visible da atribuição existente; erro de UUID ou autenticação não satisfaz essa verificação. |
| G3 | Contrato restrito a 30 pares exatos de statements explicitamente aprovados, com o alvo ligado ao predicado de chave, argumento da RPC ou parent de INSERT e à consulta de estado correspondente. SQL desconhecido é rejeitado antes de qualquer execução, inclusive como owner. Autoteste executável demonstra a falsa prova de DENY do contrato antigo com `$1` numa tautologia e alvo inexistente independente. Casos negativos cobrem DML, count, RPC, comentário, estado independente e CTE de estado com efeito colateral. |
| G4 | H2-REORDER/DELETE e OWNER-REORDER/DELETE passam `avaliacao_id\|questao_id` nos dois identificadores do contrato. Ambos os componentes restringem operação e consulta; a identidade retornada também contém ambos. Autotestes cobrem divergência apenas da questão e questão ausente. |
| G5 | R56-DIVERGENT usa identificadores distintos e SQL aprovado, exigindo `TARGET_MISMATCH`. R56-MALFORMED usa SQL aprovado com `not-a-uuid`, exigindo `STATE_QUERY_ERROR` e `22P02`; não pode passar por mera ausência textual de parâmetro. |
| G6 | A captura de baseline continua antes do setup; setup continua como owner na mesma subtransação da operação, com rollback conjunto. Erros de setup são separados dos erros da RPC: `SETUP_ERROR` no helper legado; `INCONCLUSIVE`, motivo `SETUP_ERROR`, no bound. Cobertura verifica baseline sem setup, setup que habilita correção, identidade de owner, rollback do estado/marker e erro `42501` de setup sem falsa prova de negação da RPC. |
| G7 | Comentário duplicado removido. |
| M20 | `expected`, `observed` e `result` são explicitamente `INVALID`. Echo e expectation não dizem PASS. M20 fica fora do denominador KILLED/SURVIVED e dos PASS válidos. M21 permanece autoteste, separado das mutações de controles. |

Autotestes arquivam seus resultados em `qa_selftest_results`, separados de `qa_results`, com notices e resultados finais completos. As expectativas das mutações emitem evidência antes do rollback; `qa_mutation_results` registra grupos concluídos somente depois das verificações exigidas. O plano contém **22 grupos de controle válidos**, **M20 INVALID** e **M21 autoteste**. Esses números são o inventário estático, não resultados executados.

F1 foi preservado: entradas existentes da matriz de pontos, validações de erro e mutações estreitas M22/M23. F2 mantém as regressões de identidade divergente nas duas direções para DML/count/RPC, além de malformed/NULL e controles autorizados/não autorizados. Nenhuma migration, função de produção, política RLS, contrato público ou comportamento funcional do produto foi alterado.

## Reprodução em ambiente apropriado

Pré-requisitos: Bash, Git, Docker com daemon local, OpenSSL, sha256sum, sed e tee. Node é necessário para a checagem estática. Use um checkout limpo do SHA final congelado informado na entrega; salve evidências fora desse checkout.

```bash
git rev-parse HEAD
git status --porcelain
node tests/school/verify-sc004-r58.mjs
bash -n tests/school/run-sc004-r58.sh
docker pull supabase/postgres:15.14.1.167
bash tests/school/run-sc004-r58.sh
```

O runner prefere a imagem fixada no CI canônico, `supabase/postgres:15.14.1.167`, e exige que esteja disponível localmente. Não a substitui silenciosamente por PostgreSQL genérico. `SC004_QA_IMAGE` permite uma substituição explícita, registrada nas evidências, caso uma auditoria indique outra imagem. `SC004_QA_EVIDENCE_DIR` seleciona uma pasta externa de saída; o padrão é uma pasta temporária única.

O container é novo e descartável, sem portas publicadas, sem volume de dados e com `--network none`. O replay utiliza os arquivos canônicos de migrations intactos, em ordem, com `ON_ERROR_STOP`, bootstrap compatível e default ACL fiel ao CI. A senha local é gerada por execução, injetada por ambiente e redigida nos logs. Os dois arquivos SQL rodam **na mesma sessão psql**, que configura o dblink para loopback do container e mantém os helpers `pg_temp` compartilhados. O container é removido ao encerrar, inclusive em falha.

Evidências geradas: SHA/branch/base e hashes de fontes, diff binário exato da base ao HEAD, identidade da imagem, logs completos do bootstrap, cada migration e runtime SQL, log do container, resultados normais em CSV, autotestes em CSV, mutações em CSV e contagens. `status.txt` diferencia `BLOCKED`, `RUNTIME_FAILED` e `RUNTIME_COMPLETED`; o último só é escrito se toda a sessão terminar sem erro. Um erro não produz contagem de sucesso inventada.

## Verificações locais e riscos residuais

A checagem estática passou: 30 pares aprovados, 56 callers bound, seis statements adversariais rejeitados, quatro casos de chave composta, UUIDs dos atores, preservação de F1/F2 e inventário separado de mutações. Também verifica que todas as entradas preexistentes dos probes legados permaneceram iguais. `bash -n` verifica somente sintaxe do runner. Ambos devem ser reproduzidos no candidato congelado; os logs locais completos acompanham a entrega fora do Git.

SQL, bootstrap, replay, normal tests, mutações, autotestes e concorrência PostgreSQL permanecem **NOT RUN** neste ambiente. O runner também precisa de sua primeira execução completa. Há dependência deliberada dos pares exatos do allowlist: novos statements precisam de revisão explícita do predicado e do estado correspondente; pequenas diferenças de texto falham fechadas. M20 continua sem uma mutação estreita válida para isolamento exclusivo de serialização. A classificação dos demais helpers legados não foi generalizada nesta fatia.

Depois da reprodução de runtime, o SHA exige auditoria independente de quem implementou R5.8. Não houve push, PR, merge, deploy nem acesso a banco remoto; esta entrega não autoriza gates posteriores.
