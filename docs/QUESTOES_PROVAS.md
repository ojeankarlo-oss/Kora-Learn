# Questões & Provas

## Decisão de schema

O SQL recebido no sprint usa nomes em inglês (`questions`, `quizzes`, `question_alternatives` e outras tabelas). O Kora Learn já possui um schema canônico versionado em português nas migrations 017 e 019, com RLS multi-tenant, RPCs de tentativa/correção e as tabelas `questoes`, `avaliacoes`, `avaliacao_questoes`, `avaliacao_tentativas` e `avaliacao_respostas`.

O SQL em inglês **não deve ser executado em paralelo**: isso criaria um segundo modelo de dados sem as mesmas policies e quebraria a camada atual de API. A implementação do sprint foi mapeada para o schema canônico existente.

| Requisito do sprint | Implementação Kora Learn |
|---|---|
| `question_types` | Coluna `questoes.tipo` com valores de questão objetiva/dissertativa |
| `questions` | `questoes` |
| `question_alternatives` | Campo JSONB `questoes.alternativas` |
| `quizzes` | `avaliacoes` |
| `quiz_questions` | `avaliacao_questoes` |
| `quiz_responses` | `avaliacao_tentativas` |
| `question_responses` | `avaliacao_respostas` |

A migration `019_kora_learn_resposta_dissertativa.sql` adiciona `questoes.resposta_esperada` para referência do professor na correção manual. A aplicação dessa migration no Supabase precisa ser confirmada separadamente.

## API

A API existente já possui operações específicas do produto: `criarQuestao`, `listarQuestoesDisciplina`, `criarAvaliacao`, `vincularQuestoesAvaliacao`, `atualizarSituacaoAvaliacao`, `tentativasAvaliacao` e `corrigirRespostaAvaliacao`.

Também foram adicionados wrappers compatíveis com o contrato inicial do sprint:

- `listarQuestoes({ disciplinaId, tipo, busca })`;
- `obterQuestao(questaoId)`;
- `deletarQuestao(questaoId)`, usando baixa lógica com `ativa = false`;
- `criarQuiz(...)`, traduzindo para `criarAvaliacao` e `vincularQuestoesAvaliacao`.

Os wrappers mantêm o filtro por disciplina, a filtragem de questões ativas e o fallback temporário enquanto a coluna `resposta_esperada` não estiver aplicada.

## Interface

A interface do professor permite cadastrar questões objetivas com alternativas adicionáveis/removíveis e radio button para o gabarito. Também permite questões dissertativas com resposta esperada opcional. A montagem da prova lista as questões da disciplina com resumo, tipo, dificuldade, pontuação e checkbox de seleção.

O gestor acessa o módulo por `T.modulos.provas`, alinhado à configuração do tenant. O portal do aluno usa os RPCs de avaliações disponíveis, início de tentativa e envio de respostas.

## Validações da entrega

Em ambiente sem login foram executados:

```text
npm ci
npm run lint              # 0 avisos, 0 erros
npm run build             # sucesso; apenas aviso não bloqueante de bundle > 500 kB
npm run check:encoding    # 63 arquivos UTF-8 válidos
grep -R -F '\\u00' src/  # LIMPO
git diff --check          # sem problemas
```

A consulta pública do Supabase não confirma dados protegidos de questões sem sessão de usuário; um retorno HTTP 401 é esperado sob RLS. O teste autenticado de ponta a ponta deve ser realizado em ambiente de QA com usuário de teste.
