# Plano de migração

O que já foi portado do Logistic Pipes, o que falta, e em que ordem — com o que cada peça precisa
para ser feita.

Este arquivo existe porque as listas anteriores viviam em dois repositórios e envelheceram em
silêncio: o acompanhamento do loader ainda dava `supplier`, `satellite` e `crafting` como pendentes
depois de os três estarem prontos. **Uma lista que envelhece manda trabalhar no que já está feito.**

**Regra:** ao portar uma peça, risque-a na mesma mudança que a implementa.

---

## Como a migração funciona

O mod original é **Java**: registro, renderização, rede e interface, tudo em código. Aqui ele é
**declarativo** — `mod.json` com o conteúdo, Lua com a lógica —, e o loader é quem acompanha a
versão do Minecraft.

Três decisões valem para tudo que ainda falta:

**A lógica é lida e reescrita, nunca copiada.** O código do original é estudado para entender *o
que* ele faz e *por quê* — a ordem de atendimento de um pedido, quando um cano desenha a manga, como
ele evita pedir duas vezes — e a implementação é escrita do zero no formato do loader.

**A arte é reusada de verdade.** Os `.obj` e os `.png` vêm do repositório original, sem alteração,
e por isso **este repositório é MMPL**, como ele. É também por isso que o mod não vive dentro do
mine-loader, que é MIT: quem clonasse o loader herdaria a obrigação do copyleft sem saber. A origem
de cada pasta está em `logistica/assets/logisticspipes/ORIGEM.md`.

**O que falta no loader vira tarefa do loader.** Sete limites já saíram assim — forma que varia com
o estado, tique agendado por posição, inventário por slot, e outros. Ao esbarrar em algo que o
loader não faz, o caminho é abrir a lacuna lá, e não contornar aqui.

---

## Portado

| Peça | No original | O que faz |
|---|---|---|
| `cano` | `basic` | transporta; o item **viaja** de cano em cano, um passo a cada quatro tiques |
| `provedor` | `provider` | oferece à rede o estoque do baú encostado nele |
| `terminal` | `request` | tela de pedido; entrega no baú encostado |
| `abastecedor` | `supplier` | mantém um baú em estoque, contando o que já está a caminho |
| `satelite` | `satellite` | endereço nomeado, para a rede se reconfigurar sem reeditar cano |
| `fabricador` | `crafting` | **árvore de pedido** com bancada 3×3: o padrão escolhe a receita, o que falta é fabricado, e cada ingrediente vira um pedido novo |

| `chassi` | `chassis` | nove slots de módulo; o comportamento vem do que está dentro |
| `provedor_mk2` | `provider_mk2` | manda uma pilha por pedido, contra 16 do Mk1 |
| `fabricador_mk2` / `mk3` | `crafting_mk2` / `mk3` | a árvore de pedido desce mais fundo |

**Módulos de chassi**

| Módulo | No original | O que faz |
|---|---|---|
| `extrator` | `extractor` | tira do baú e manda para quem aceitar — ou para um **satélite nomeado** |
| `deposito` | `item_sink` | declara que este baú recebe um item |
| `abastecedor` | `passive_supplier` | mantém o baú numa quantidade |
| `separador` | `quick_sort` | manda embora **tudo** que achar, cada item para quem o aceitar |
| `descarte` | `terminus` | aceita o que ninguém quer e destrói — **último destino, nunca o primeiro** |
| `fabricante` | `crafter` | ensina a rede a fazer um item, pelo padrão de bancada do slot |

O desenho vem do modelo do original, recortado por conexão: miolo sempre, manga no lado ligado,
parede e decalque no lado livre.

---

## O que falta, em ordem

### ~~1. Chassi e módulos~~ — **feito**

O bloco existe, com nove slots, e os módulos `extrator`, `deposito` e `abastecedor` funcionam:
um baú exporta sozinho, outro recebe, e a rede liga os dois sem ninguém pedir. Verificado no
servidor -- 32 barras saíram de um baú e chegaram ao outro.

Os seis módulos existem. `active_supplier` **não virou um módulo próprio de propósito**: o
`abastecedor` daqui já pede à rede o que falta, que é o comportamento ativo — um segundo módulo com
o mesmo efeito e nome diferente seria confusão, não recurso.

Cada um tem caso na bateria, inclusive o chassi, que era débito conhecido.

O texto abaixo é o plano original, mantido porque descreve o que ainda vale para os que faltam.

#### O plano

No original, o `chassis` é um cano com **slots de módulo**: cada módulo dá um comportamento
(extrair, filtrar, abastecer, ordenar), e o chassi mk1 a mk5 muda quantos cabem.

É o que resta de substancial, e o que mais muda como se joga: sem ele a rede é manual.

**O que precisa:** ler e escrever slot de inventário — **já existe** no loader desde que
`insert_into` e `extract_from` passaram a aceitar índice. Não há limite bloqueando.

**Como fazer, na ordem:**

1. O bloco `chassi`, com `block_data` guardando a lista de módulos por slot.
2. Os módulos como **itens declarados**, cada um com um id — o chassi lê o que está no inventário
   dele e age conforme.
3. Um módulo de cada vez, começando pelos três que sustentam o resto:
   - `extractor` — tira do baú encostado e manda para a rede
   - `item_sink` — declara "este item mora aqui", e a rede entrega aqui
   - `passive_supplier` — mantém estoque, como o abastecedor, mas por módulo

Os outros (`quick_sort`, `terminus`, `crafter`, `active_supplier`) são variações do mesmo
mecanismo, e ficam mais baratos depois que o primeiro existir.

**Onde vai doer:** o chassi consulta os módulos a cada tique. Cada consulta lê `block_data` e o
inventário, e tudo isso roda num callback com 20 ms. O abastecedor já esbarrou nisso e a solução
foi guardar um número em vez de varrer — o chassi vai precisar da mesma disciplina.

### 2. Variantes mk2 e mk3 — **parcial**

`provedor_mk2`, `fabricador_mk2` e `fabricador_mk3` existem. A diferença é numérica, como no
original: quanto o provedor manda por pedido, e quão fundo a árvore desce. **O melhor fabricador da
rede manda nos limites** — pendurar um Mk3 faz a árvore descer mais fundo sem mexer em mais nada.

Ao acrescentá-los, a pergunta "isto é um provedor?" saiu de quatro arquivos para uma tabela em
`rede.lua`. Estava escrita como `no.bloco == "logistica:provedor"` em cada um, e esquecer um daria
um provedor que aparece na rede e nunca entrega — sem erro nenhum no log.

**Faltam:** `request_mk2` (no original ele é o pedido remoto, e depende de item com tela própria) e
os chassis mk1 a mk5 — o número de slots é o que os diferencia, e a janela do jogo exige múltiplo
de nove. Reproduzir exige limitar por lógica quantos slots contam, ou uma tela própria.

### 3. Periféricos

| Peça | O que é | Observação |
|---|---|---|
| `firewall` | filtra o que atravessa entre sub-redes | precisa de filtro por item, que o chassi traz |
| `analyzer` | mostra o que passa pelo cano | depende de tela; a do terminal serve de base |
| `destination`, `entrance` | roteamento explícito | pequenos, dependem de rota nomeada — o satélite já tem a ideia |
| `remote_orderer` | pedir de longe, como item | precisa de item com tela própria |
| `beesink`, `invsyscon`, `thaumic_aspect_sink` | integração com Forestry, ComputerCraft e Thaumcraft | **não portáveis**: os mods de origem não existem aqui |

### 4. Fluidos, e os tubos de alta velocidade

Toda a família `liquid_*` e os `hs-*`.

**Bloqueado no loader:** não há API de fluido. Está em `docs/API_GAPS.md` do mine-loader como
lacuna de conteúdo, e é um trabalho de plataforma, não deste mod.

---

## Como verificar

```bash
# no repositório do loader, apontando este mod
./gradlew :runClient -Pmods=/caminho/deste/repo/logistica

# a bateria do mod, dentro do jogo
/mod logistica autoteste
```

A bateria monta redes de verdade num canto do mundo, exercita o ciclo e desmonta — **um caso por
tique**, porque cada callback tem 20 ms e a bateria inteira num só dividia esse orçamento entre
todos.

**Ela roda nas duas plataformas, e é de propósito.** O mesmo manifesto tem que se comportar igual no
Fabric e no NeoForge; foi assim que se descobriu que `extract_from` respeitava `allow_extract` num
lado e não no outro.

---

## A refinar

O que já funciona mas está mais simples que o original. Nenhum destes bloqueia o resto — são
lugares onde a versão de hoje escolheu o caminho curto, e vale saber qual foi.

### Chassi

- **Sem prioridade entre depósitos.** Quem aceita um item é o primeiro encontrado, e a varredura
  devolve os canos em ordem de distância — então vence o mais perto. O original tem prioridade
  explícita por módulo, e é o que permite "manda para a fundição; se ela estiver cheia, para o
  armazém". Sem isso, dois depósitos do mesmo item são indistinguíveis.
- **Nove slots, e não um a cinco.** A janela do jogo tem fileiras de nove, e o loader recusa
  `inventory.size` que não seja múltiplo disso. O original tem `chassi_mk1` a `mk5`, com um a cinco
  slots — o número é o que diferencia as variantes. Reproduzir isso exige limitar por lógica quantos
  slots contam, ou uma tela própria em vez da janela do jogo.
- **O módulo abastecedor não conta o que está a caminho.** O cano abastecedor conta, e foi
  justamente esse detalhe que o impediu de encher o baú com várias vezes o alvo. O módulo repete a
  versão ingênua e pede de novo enquanto a remessa viaja.
- **Um módulo por slot, sem filtro composto.** O original combina filtros (por mod, por tag, por
  encantamento) num mesmo módulo. Aqui é um item por slot, e ponto.

### Fabricador

**O sistema hoje.** O cano abre uma janela declarada com a forma da bancada: grade **3×3** para o
padrão, **slot de saída** ao lado, botão **Importar** embaixo, e o inventário do jogador. Os slots
são fantasma — nada é consumido ao desenhar. Três formas de preencher:

| Como | Quando |
|---|---|
| `/mod logistica importar` | há uma bancada montada encostada no cano — lê o arranjo e o produto |
| arrastar item nos slots | montar à mão; nada é consumido, os slots são fantasma |
| `/mod logistica resultado <item> [qtd]` | declarar o que sai, quando o jogo não sabe dizer |

**O resultado declarado vence o livro de receitas, e é isso que torna o sistema genérico.** Sem ele,
a rede só sabe fabricar o que a bancada do jogo faz. Com ele, o mesmo cano serve a qualquer máquina
acoplada — forno, moedor, prensa de outro mod: o padrão diz o que entra, o resultado diz o que sai,
e nem o mod nem o loader precisam entender a máquina do meio.

O terminal lista o que a rede **sabe fazer** junto do que ela **tem**, com o botão escrito "Fazer"
em vez de "Pedir". Sem isso um cano fabricador só servia a quem já sabia de cor que ele estava lá, e
o pedido tinha que ser digitado no escuro.

- **Não usa bancada de verdade.** Ele consome os ingredientes e produz o resultado. O efeito para
  quem joga é o mesmo e a conta fecha — nada aparece sem que o material tenha sumido —, mas não há
  bancada envolvida. ~~O loader não tem API para isso.~~ **Tem**: `crafting_result(padrão)` recebe
  nove slots e devolve o que sai, perguntando ao próprio jogo — a mesma busca que a bancada faz, com
  e sem formato. O que falta é o cano *consumir por ali*, e não a pergunta.
- ~~**Sempre a primeira receita.**~~ **Resolvido pelo padrão.** `planejar` continua pegando
  `receitas[1]`, e por isso pedir pelo nome do produto ainda pode escolher a receita errada. Mas o
  fabricador tem bancada 3×3, e `planejar_padrao` usa o arranjo que o jogador montou — que é como o
  original resolve: quem escolhe a receita é quem tem o material.
- ~~**A posição da receita vale o primeiro item.**~~ **Corrigido**, e era mais grave do que a nota
  antiga sugeria: pedir um baú numa base cheia de carvalho descia para tora de selva e desistia com
  "ninguém sabe fazer". A tag `#planks` aceita qualquer madeira e a lista vem numa ordem que o mod
  não escolhe. Agora a escolha é **o que a rede tem**, e o estoque é lido uma vez por árvore — o que
  a nota temia (multiplicar o custo) não aconteceu porque ele já era lido a cada nó.
- **Sem reserva entre pedidos.** Dois pedidos seguidos no mesmo tique podem planejar contando o
  mesmo material: a reserva vale dentro de uma árvore, não entre duas.

### Satélite

- ~~**Ninguém rotea por ele ainda.**~~ **Fechado.** Um slot extrator aponta para um satélite pelo
  nome (`/mod logistica destino <slot> <nome>`), e entrega lá em vez de procurar quem aceita. São
  duas perguntas diferentes e o original tem as duas: *quem quer isto* e *onde fica a forja*. Nome
  que não existe não vira entrega em outro lugar — a produção da forja indo para um baú qualquer é
  o tipo de defeito que só aparece quando falta material lá na frente.

### Verificação

- ~~**O chassi ainda não tem caso na bateria.**~~ **Pago.** `chassi_extrai_e_deposita` monta a rede,
  extrai sem ninguém pedir e confere que chegou. Junto vieram `descarte_e_o_ultimo_destino`,
  `fabricante_vence_a_receita_do_jogo` e `extrator_entrega_no_satelite`.

## Débito conhecido

**O render de malha do Fabric está com defeito** — o NeoForge desenha certo, com o mesmo pacote e os
mesmos números de face. Não é deste mod: está registrado em `docs/COMPATIBILIDADE.md` do loader, com
o que já foi descartado e onde procurar.

Não bloqueia nada daqui. O desenho é do cliente; a rede, a viagem e os pedidos funcionam igual nos
dois.
