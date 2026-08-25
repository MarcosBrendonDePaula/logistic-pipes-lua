# Logística — Logistic Pipes no Mine Loader

Um porte da ideia central do [Logistic Pipes](https://github.com/rs485/logisticspipes) para o
[Mine Loader](https://github.com/MarcosBrendonDePaula/mine-loader): uma rede de canos que encontra
e entrega itens, escrita **sem uma linha de Java** — só `mod.json` e Lua.

É o **primeiro mod migrado** para aquele loader, e não por acaso: o Logistic Pipes parou de ser
atualizado pelo motivo exato que o loader existe para resolver.

## Como rodar

O mod nao precisa ser copiado para dentro do loader. Aponte esta pasta e o Mine Loader le direto
daqui:

```bash
cd /caminho/do/mine-loader
./gradlew :runClient -Pmods=/caminho/deste/repo/logistica
```

Ou, por variavel de ambiente:

```bash
MINE_LOADER_MODS=/caminho/deste/repo/logistica ./gradlew :runServer
```

Copiar era a alternativa, e a copia envelhece: o servidor passa a rodar contra um script velho
**dizendo que passou**.

## O que ja funciona

- **Cano, provedor e terminal**, com o ciclo completo: o terminal pergunta a rede o que existe, e o
  provedor tira do bau ao lado e manda.
- **Os canos se conectam.** Cada um cresce braco em direcao ao vizinho, e a colisao acompanha o
  desenho -- ver o braco e atravessa-lo seria pior que nao ter braco.
- **O item viaja.** Ele anda de cano em cano, um passo a cada quatro tiques, em vez de sumir de um
  bau e aparecer no outro. A carga em viagem mora nos dados do proprio cano, entao sobrevive ao
  servidor cair e some junto com o cano em vez de apontar para uma posicao que nao existe mais.
- **Item nao desaparece.** Cano quebrado no meio da viagem descarrega no inventario vizinho, e bau
  de destino cheio segura a carga em fila.

## O que falta

`supplier`, `satellite`, `crafting` e os modulos de `chassis`. O `crafting` e o unico que precisa de
ideia nova -- recursao de pedido, a arvore que o original chama de RequestTree.


## Por que portar um mod que parou

O Logistic Pipes não parou por falta de ideia. Acompanhar as versões do Minecraft em Java custa
caro: cada atualização mexe em registro, em renderização e em rede, e alguém precisa refazer esse
trabalho todo ano.

Um mod declarativo não paga esse preço. Quem acompanha a versão do jogo é o loader; o mod continua
sendo o mesmo JSON e o mesmo Lua. É essa a aposta que este repositório testa.

## O que já funciona

| Bloco | O que faz |
|---|---|
| **Cano Logístico** | conduz e forma a rede |
| **Cano Provedor** | oferece à rede o baú encostado nele, 16 itens por pedido |
| **Terminal Logístico** | tela que lista o que a rede tem e entrega no baú ao lado |

O ciclo completo está de pé: o terminal varre a rede, soma o que os provedores têm, e um pedido tira
do baú de origem e põe no de destino.

Duas fidelidades vêm do código original, e não de memória:

- **os provedores mais perto atendem primeiro** — o original pede por custo (`getIRoutersByCost`),
  e a busca em largura já devolve nessa ordem;
- **provedor que divide o baú com quem pediu é pulado** — sem isso, um baú que é origem e destino
  faria o item sair e voltar para sempre, e a rede pareceria trabalhar sem nada acontecer.

## Instalar

Copie a pasta `logistica/` para `mods-lua/` do seu jogo. Precisa do Mine Loader instalado.

## Conferir sem estar no jogo

```
/mod logistica ver   <x> <y> <z>            o que a rede enxerga a partir dali
/mod logistica pedir <x> <y> <z> <item>     entrega, como o botão da tela faria
```

## O que ainda falta

O porte encontrou limites reais do loader, todos registrados em `API_GAPS.md` lá:

- **não há tique agendado por posição**, então o item some de um baú e aparece no outro sem viagem
  visível — é a maior diferença para o original;
- **não há leitura de inventário por slot**, o que impede reproduzir os filtros dos módulos de
  chassi;
- **não há evento de bloco quebrado com o inventário íntegro**, então a rede se refaz ao abrir a
  tela em vez de reagir sozinha.

Nada disso é limitação da ideia — são itens de API, e cada um fechado aqui vale para todo mod.

## Créditos e licença

A ideia, o desenho da rede e os arquivos em `logistica/assets/lp_*.png` e `logistica/models/lp_*`
vêm do **Logistic Pipes**, de Krapht, davboecki, RS485 e demais contribuidores.

Este repositório é distribuído sob a **Minecraft Mod Public License (MMPL) v1.0.1**, a mesma do
original — é o que a licença exige de qualquer derivado, e a razão de este porte viver aqui e não
dentro do repositório do Mine Loader, que é MIT.

Os arquivos `cano.png`, `provedor.png` e `terminal.png` foram desenhados do zero para este porte.
