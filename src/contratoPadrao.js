export const CONTRATO_PADRAO_VERSAO = "kora-1.0";

export const CONTRATO_PADRAO_MD = `CONTRATO DE PRESTAÇÃO DE SERVIÇOS EDUCACIONAIS

CONTRATADA: {{instituicao_nome}}, pessoa jurídica de direito privado, inscrita no CNPJ sob nº {{instituicao_cnpj}}, com sede em {{instituicao_endereco}}, doravante denominada INSTITUIÇÃO.

CONTRATANTE: {{aluno_nome}}, inscrito(a) no CPF sob nº {{aluno_cpf}}, e-mail {{aluno_email}}, doravante denominado(a) ALUNO(A) — ou, sendo menor de 18 anos, representado(a) por seu responsável legal identificado no ato da matrícula.

As partes celebram o presente contrato, que se regulará pelas cláusulas seguintes, pelo Código de Defesa do Consumidor (Lei 8.078/90), pela Lei 9.870/99 e demais normas aplicáveis.

Cláusula 1ª — Do Objeto

1.1. O objeto deste contrato é a prestação, pela INSTITUIÇÃO, dos serviços educacionais referentes ao curso {{curso_nome}}, com carga horária de {{carga_horaria}} horas, na modalidade {{modalidade}}, vinculado à unidade {{unidade_nome}}. 1.2. Os serviços compreendem o acesso ao ambiente virtual de aprendizagem, aos materiais didáticos digitais do curso e às avaliações previstas no plano de ensino.

Cláusula 2ª — Da Matrícula e do Acesso

2.1. A matrícula efetiva-se com o aceite eletrônico deste contrato e a confirmação dos dados cadastrais. 2.2. O acesso à plataforma é pessoal e intransferível; o(a) ALUNO(A) responsabiliza-se pela guarda de suas credenciais.

Cláusula 3ª — Do Preço e do Pagamento

3.1. Pelo curso ora contratado, o(a) ALUNO(A) pagará o valor total de R$ {{valor_total}}, na forma de {{condicoes_pagamento}}. 3.2. Cursos gratuitos ou subsidiados por convênio terão o valor indicado como R$ 0,00, permanecendo válidas as demais cláusulas.

Cláusula 4ª — Da Inadimplência

4.1. O atraso no pagamento sujeita o(a) ALUNO(A) a multa de 2% (dois por cento) sobre o valor da parcela, juros de mora de 1% (um por cento) ao mês e atualização monetária. 4.2. Nos termos do art. 6º da Lei 9.870/99, a inadimplência não ensejará a suspensão de provas, a retenção de documentos escolares ou a aplicação de quaisquer penalidades pedagógicas ao(à) ALUNO(A) durante o período letivo contratado.

Cláusula 5ª — Do Cancelamento e do Arrependimento

5.1. Sendo a contratação realizada fora do estabelecimento comercial (meio eletrônico), o(a) ALUNO(A) poderá desistir do contrato no prazo de 7 (sete) dias corridos a contar do aceite, com devolução integral dos valores pagos (art. 49 do CDC). 5.2. Após esse prazo, o cancelamento poderá ser solicitado a qualquer tempo pela plataforma, cessando a cobrança das parcelas vincendas, sendo devidos os valores proporcionais aos serviços já disponibilizados.

Cláusula 6ª — Das Obrigações da Instituição

6.1. Disponibilizar o conteúdo do curso conforme o plano de ensino; manter a plataforma em funcionamento adequado, ressalvadas manutenções e casos fortuitos; emitir o certificado de conclusão ao(à) ALUNO(A) que cumprir os requisitos do curso.

Cláusula 7ª — Das Obrigações do(a) Aluno(a)

7.1. Utilizar a plataforma conforme sua finalidade educacional; não reproduzir, distribuir ou comercializar os materiais do curso, protegidos por direitos autorais; manter seus dados cadastrais atualizados.

Cláusula 8ª — Da Proteção de Dados (LGPD)

8.1. A INSTITUIÇÃO tratará os dados pessoais do(a) ALUNO(A) exclusivamente para a execução deste contrato, o cumprimento de obrigações legais e regulatórias e a comunicação sobre o curso, nos termos da Lei 13.709/2018 (LGPD). 8.2. Sendo o(a) ALUNO(A) menor de 18 anos, o tratamento de seus dados dá-se com o consentimento específico do responsável legal, colhido no ato da matrícula. 8.3. O(a) titular poderá exercer seus direitos (acesso, correção, eliminação, portabilidade) pelos canais de atendimento da INSTITUIÇÃO.

Cláusula 9ª — Do Aceite Eletrônico

9.1. As partes reconhecem a validade jurídica do aceite eletrônico realizado na plataforma, registrado com identificação do usuário, data, hora e código de verificação (hash) do exato teor deste documento, nos termos da MP 2.200-2/2001 e do art. 107 do Código Civil.

Cláusula 10ª — Do Foro

10.1. Fica eleito o foro da comarca de domícilio do(a) ALUNO(A) para dirimir controvérsias oriundas deste contrato, nos termos do CDC.

Aceite registrado eletronicamente na plataforma em {{data_aceite}}, pelo usuário {{aluno_email}}, hash {{hash_documento}}.`;

const PLACEHOLDERS = [
  "instituicao_nome", "instituicao_cnpj", "instituicao_endereco",
  "aluno_nome", "aluno_cpf", "aluno_email",
  "curso_nome", "carga_horaria", "modalidade", "unidade_nome",
  "valor_total", "condicoes_pagamento", "data_aceite", "hash_documento",
];

export function preencherContrato(md, dados = {}) {
  let texto = String(md ?? "");
  for (const campo of PLACEHOLDERS) {
    const valor = dados ? dados[campo] : undefined;
    const valorFinal = (valor === undefined || valor === null || valor === "") ? "—" : String(valor);
    texto = texto.split(`{{${campo}}}`).join(valorFinal);
  }
  return texto;
}

export async function hashTexto(texto) {
  const encoder = new TextEncoder();
  const dados = encoder.encode(String(texto ?? ""));
  const hashBuffer = await crypto.subtle.digest("SHA-256", dados);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}
