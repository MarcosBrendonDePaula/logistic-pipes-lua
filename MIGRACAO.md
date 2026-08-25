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
| `fabricador` | `crafting` | **árvore de pedido**: o que falta é fabricado, e cada ingrediente vira um pedido novo |

O desenho dos seis vem do modelo do original, recortado por conexão: miolo sempre, manga no lado
ligado, parede e decalque no lado livre.

---

## O que falta, em ordem

### 1. Chassi e módulos — **primeiros três feitos**

O bloco existe, com nove slots, e os módulos `extrator`, `deposito` e `abastecedor` funcionam:
um baú exporta sozinho, outro recebe, e a rede liga os dois sem ninguém pedir. Verificado no
servidor -- 32 barras saíram de um baú e chegaram ao outro.

Falta o resto da família (`quick_sort`, `terminus`, `crafter`, `active_supplier`), que são
variações destes, e o que está em **A refinar** abaixo.

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

### 2. Variantes mk2 e mk3

`provider_mk2`, `request_mk2`, `crafting_mk2`, `crafting_mk3`, e os chassis mk1 a mk5.

São o mesmo cano com números maiores — quanto manda por pedido, quantos slots tem. Trabalho
mecânico, e as texturas já estão aqui.

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

- **Não usa bancada de verdade.** Ele consome os ingredientes e produz o resultado. O efeito para
  quem joga é o mesmo e a conta fecha — nada aparece sem que o material tenha sumido —, mas não há
  bancada envolvida, e o loader não tem API para isso.
- **Sempre a primeira receita.** Um item com várias formas de ser feito usa a primeira que o jogo
  devolve, sem escolher pela que tem ingrediente disponível. O original tenta as alternativas.
- **A posição da receita vale o primeiro item.** Uma posição que aceita carvão *ou* carvão vegetal
  usa carvão, mesmo que só haja o vegetal em estoque. Escolher pelo que existe exigiria consultar o
  estoque dentro do planejamento, o que multiplica o custo de montar a árvore.
- **Sem reserva entre pedidos.** Dois pedidos seguidos no mesmo tique podem planejar contando o
  mesmo material: a reserva vale dentro de uma árvore, não entre duas.

### Satélite

- **Ninguém rotea por ele ainda.** Ele guarda o nome e a rede o encontra, mas nenhum outro cano usa
  isso como destino. É a metade que falta para ele servir para o que serve no original.

### Verificação

- **O chassi ainda não tem caso na bateria.** Foi verificado à mão no servidor: 32 barras saíram
  sozinhas de um baú e chegaram ao outro. Sem caso automático, ele quebra em silêncio na próxima
  mudança — é o mesmo débito que o fabricador teve e que já foi pago.

## Débito conhecido

**O render de malha do Fabric está com defeito** — o NeoForge desenha certo, com o mesmo pacote e os
mesmos números de face. Não é deste mod: está registrado em `docs/COMPATIBILIDADE.md` do loader, com
o que já foi descartado e onde procurar.

Não bloqueia nada daqui. O desenho é do cliente; a rede, a viagem e os pedidos funcionam igual nos
dois.
