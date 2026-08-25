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

### 1. Chassi e módulos — o pedaço grande

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

## Débito conhecido

**O render de malha do Fabric está com defeito** — o NeoForge desenha certo, com o mesmo pacote e os
mesmos números de face. Não é deste mod: está registrado em `docs/COMPATIBILIDADE.md` do loader, com
o que já foi descartado e onde procurar.

Não bloqueia nada daqui. O desenho é do cliente; a rede, a viagem e os pedidos funcionam igual nos
dois.
