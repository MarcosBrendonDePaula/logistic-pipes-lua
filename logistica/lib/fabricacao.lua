-- O cano fabricador: pedir o que a rede nao tem, fabricando.
--
-- No original ele e o `crafting`, e e o unico cano que precisa de uma ideia nova. Os outros movem
-- o que ja existe; este responde "nao tenho, mas sei fazer" -- e para fazer precisa dos
-- ingredientes, que tambem podem nao existir e tambem podem ser fabricados.
--
-- A ideia e a arvore de pedido, que o mod original chama de RequestTree. Para atender N unidades de
-- um item, na ordem:
--
--   1. o que ja existe nos provedores
--   2. o que sobrou de uma fabricacao ja planejada nesta mesma arvore
--   3. fabricar -- e cada ingrediente vira um pedido novo, pelas mesmas tres regras
--
-- A logica e essa; o codigo e escrito aqui, para o formato declarativo do loader.
--
-- **O plano e montado antes de qualquer item se mexer.** Um pedido que descobre no meio do caminho
-- que falta um ingrediente ja consumiu os outros, e a base fica com material picado e nada pronto.
-- Aqui a arvore inteira e resolvida primeiro; se algum ramo nao fecha, nada e tirado do lugar.

local rede = mod.import("lib/rede.lua")

-- Ate onde a arvore desce.
--
-- Cinco niveis cobrem madeira -> tabuas -> graveto -> ferramenta, que e o mais fundo que uma receita
-- do jogo costuma ir. O teto existe porque duas receitas podem se referenciar em circulo, e sem ele
-- a busca nao termina.
local PROFUNDIDADE = 5

-- Quantos pedidos a arvore inteira pode ter.
--
-- Cada no custa uma leitura de receita e uma varredura do estoque, e tudo isso roda dentro de um
-- callback com orcamento de 20 ms. Um pedido de mil unidades de algo com receita profunda montaria
-- uma arvore que nao cabe -- e o sintoma seria o comando parar de responder, sem dizer por que.
local MAX_NOS = 64

--- As receitas do jogo que produzem aquele item.
--
-- Vem do proprio jogo, e nao de uma receita declarada no mod: um fabricador que so soubesse fazer o
-- que o mod ensinou seria inutil num modpack, onde quase tudo vem de outro lugar.
-- Quantas receitas pedir por item.
--
-- **Uma**, porque uma e a que se usa. A resposta nao e barata: cada receita traz ate nove posicoes,
-- e cada posicao ate trinta e duas alternativas -- pedir oito era ate 2.304 cadeias de texto por
-- item, das quais 2.303 iam para o lixo. Numa arvore de 256 nos isso e memoria de sobra dentro de
-- um callback com 20 ms de orcamento.
--
-- Subir este numero e o que um "tentar a proxima receita" precisaria, e por isso ele e uma
-- constante com nome em vez de um 1 solto no meio da chamada.
local RECEITAS_POR_ITEM = 1

local function receitas_de(ctx, item)
    local ok, lista = pcall(function()
        return ctx.server.recipes_for(item, RECEITAS_POR_ITEM)
    end)

    -- O erro vai para o log em vez de virar "ninguem sabe fazer". Engolir a causa aqui mandava a
    -- mensagem errada para quem pediu: parecia que o item nao tem receita, quando o que houve foi
    -- uma chamada recusada.
    if not ok then
        ctx.log.warn("LOGISTICA nao consegui ler receitas de " .. item .. ": " .. tostring(lista))
        return {}
    end
    return lista or {}
end

--- Os ingredientes de uma receita, somados por item.
--
-- Uma receita lista posicoes, e a mesma pilha pode aparecer em varias -- quatro tabuas para uma
-- bancada sao quatro posicoes de uma tabua. Somar aqui e o que torna o resto da conta simples.
--
local function ingredientes_de(receita, tem)
    local total = {}
    local ordem = {}

    -- Cada posicao e a LISTA de itens que servem ali: a receita do bau aceita tabua de qualquer
    -- madeira, e chega como todas elas.
    --
    -- **Vale o que a rede tem, e nao o primeiro da lista.** Pegar o primeiro parece inofensivo e
    -- nao e: a lista da tag vem numa ordem que o mod nao escolhe, e pedir um bau numa base cheia de
    -- carvalho descia para tora de selva e desistia com "ninguem sabe fazer". A base tinha o
    -- material o tempo todo.
    --
    -- Sem estoque conhecido, ou quando nenhuma opcao existe, vale o primeiro: a mensagem de erro
    -- precisa nomear alguma coisa concreta.
    for _, posicao in ipairs(receita.ingredients or {}) do
        local escolha = nil
        if type(posicao) == "table" then
            if tem ~= nil then
                for _, candidato in ipairs(posicao) do
                    if (tem[candidato] or 0) > 0 then
                        escolha = candidato
                        break
                    end
                end
            end
            escolha = escolha or posicao[1]
        end

        if escolha ~= nil then
            if total[escolha] == nil then
                total[escolha] = 0
                ordem[#ordem + 1] = escolha
            end
            total[escolha] = total[escolha] + 1
        end
    end

    local lista = {}
    for _, item in ipairs(ordem) do
        lista[#lista + 1] = { item = item, count = total[item] }
    end
    return lista
end

--- Quantas ordens o cano daquela oferta ja tem esperando.
--
-- O `pcall` esta ai porque a leitura falha num cano que nao declarou `block_data`, e um erro aqui
-- derrubaria o planejamento inteiro por causa de uma conta de desempate.
local function espera_do_cano(ctx, no)
    local ok, quantas = pcall(function()
        return mod.import("lib/espera.lua").pendentes(ctx, no.x, no.y, no.z)
    end)
    return ok and quantas or 0
end

--- Os ingredientes de um padrao de nove slots, somados por item.
--
-- Um padrao e a bancada como o jogador a montaria: nove posicoes, vazias ou com um item. Somar por
-- item e o que liga o padrao ao resto -- dali para baixo e o mesmo pedido de sempre.
local function ingredientes_do_padrao(padrao)
    local total = {}
    local ordem = {}

    for slot = 1, 9 do
        local item = padrao[slot]
        if item ~= nil and item ~= "" then
            if total[item] == nil then
                total[item] = 0
                ordem[#ordem + 1] = item
            end
            total[item] = total[item] + 1
        end
    end

    local lista = {}
    for _, item in ipairs(ordem) do
        lista[#lista + 1] = { item = item, count = total[item] }
    end
    return lista
end

--- O estoque da rede como mapa, lido uma vez por arvore.
--
-- `rede.estoque` varre todos os provedores; chama-la por item fazia a arvore pagar a varredura
-- inteira a cada no. Numa receita de tres niveis isso e uma varredura por ingrediente de cada
-- passo, dentro de um callback com 20 ms.
local function estoque_como_mapa(ctx, nos)
    local mapa = {}
    for _, entrada in ipairs(rede.estoque(ctx, nos)) do
        mapa[entrada.item] = (mapa[entrada.item] or 0) + entrada.count
    end
    return mapa
end

--- Quanto a rede tem daquele item, sem contar o que outro ramo ja reservou.
local function disponivel(estado, item)
    return (estado.tem[item] or 0) - (estado.reservado[item] or 0)
end

--- Resolve um pedido, montando o plano sem mexer em nada.
--
-- Devolve uma tabela com:
--
--   atendido    quanto da para atender de verdade
--   retirar     o que sai dos provedores, por item
--   fabricar    o que precisa ser feito, na ordem em que precisa ser feito
--   motivo      por que nao deu para atender tudo, quando e o caso
--
-- A ordem de `fabricar` importa: um ingrediente fabricado tem que ficar pronto antes de quem o usa,
-- e a lista sai do fundo da arvore para a raiz justamente por isso.
local function planejar(ctx, nos, item, quantidade, estado)
    estado = estado or {
        reservado = {},     -- o que ja foi prometido a outro ramo
        tem = estoque_como_mapa(ctx, nos),   -- o estoque, lido uma vez para a arvore inteira
        fabricar = {},      -- o plano, do fundo para a raiz
        retirar = {},       -- o que sai do estoque
        nos = 0,
        profundidade = 0,
    }

    -- Os limites vem do melhor fabricador que a rede tem, e nao de uma constante.
    --
    -- E o que separa as tres versoes do original: pendurar um Mk3 na rede faz a arvore descer mais
    -- fundo, sem mexer em nada mais. Lido uma vez por arvore -- perguntar a rede por no custaria
    -- uma varredura por ingrediente.
    if estado.limites == nil then
        estado.limites = rede.limites_de("logistica:fabricador")
        for _, no in ipairs(nos) do
            local limites = rede.FABRICADORES[no.bloco]
            if limites ~= nil and limites.profundidade > estado.limites.profundidade then
                estado.limites = limites
            end
        end
    end

    estado.nos = estado.nos + 1
    if estado.nos > estado.limites.nos then
        return 0, "o pedido ficou grande demais para planejar", estado
    end
    if estado.profundidade > estado.limites.profundidade then
        return 0, "a receita desce fundo demais", estado
    end

    -- 1. O que ja existe. Reservar aqui e o que impede dois ramos de contarem a mesma pilha.
    local tem = disponivel(estado, item)
    local doEstoque = math.min(tem, quantidade)
    if doEstoque > 0 then
        estado.reservado[item] = (estado.reservado[item] or 0) + doEstoque
        estado.retirar[item] = (estado.retirar[item] or 0) + doEstoque
    end

    local falta = quantidade - doEstoque
    if falta <= 0 then return quantidade, nil, estado end

    -- 2. Fabricar o que falta. Um padrao que alguem montou na rede vence a receita do jogo.
    --
    -- **A ordem importa e e a razao de o modulo fabricante existir.** As receitas do jogo vem numa
    -- ordem que o mod nao escolhe, e `receitas[1]` para um item com varias formas raramente e a que
    -- a base tem material para fazer. Um padrao num chassi e alguem dizendo "nesta base, isto se faz
    -- assim" -- e essa decisao tem que valer mais que a ordem do livro de receitas.
    --
    -- Os padroes sao lidos uma vez por arvore e guardados no estado: cada no do pedido perguntaria
    -- a rede inteira de novo, e o orcamento de 20 ms nao tem essa folga.
    if estado.padroes == nil then
        estado.padroes = mod.import("lib/chassi.lua").padroes_na_rede(ctx, nos)
    end

    local porLote, ingredientes, maquina, cano

    -- **Entre maquinas que fazem a mesma coisa, vence a de fila mais curta.**
    --
    -- Antes valia a primeira da lista e as outras ficavam paradas: montar uma segunda fornalha nao
    -- fabricava mais rapido, so gastava ferro. Pior, com a fila da primeira cheia o pedido era
    -- recusado com a segunda ociosa do lado.
    --
    -- A fila e lida so das ofertas que servem para este item -- poucas --, e nao de toda a rede.
    local melhor, menorFila = nil, nil
    for _, oferta in ipairs(estado.padroes) do
        if oferta.saida.item == item then
            local fila = 0
            if oferta.maquina ~= nil and oferta.no ~= nil then
                fila = espera_do_cano(ctx, oferta.no)
            end
            if menorFila == nil or fila < menorFila then
                melhor, menorFila = oferta, fila
            end
        end
    end

    for _, oferta in ipairs(estado.padroes) do
        if oferta == melhor then
            -- Quem filtra o declarado sem maquina e `padroes_na_rede`: a lista ja chega com o
            -- que a rede realmente sabe fazer, e conferir de novo aqui daria dois lugares para a
            -- mesma regra.
            porLote = oferta.saida.count
            -- A lista do mapa vence o desenho 3x3: o desenho para de contar em nove celulas, e
            -- uma receita de dezesseis nao caberia nele.
            ingredientes = oferta.ingredientes or ingredientes_do_padrao(oferta.padrao)
            maquina = oferta.maquina
            cano = oferta.no
            break
        end
    end

    if ingredientes == nil then
        -- Sem padrao e sem receita, o pedido para aqui -- e o caso comum: minerio nao se fabrica,
        -- se cava.
        -- A receita ja resolvida, guardada por arvore.
        --
        -- Duas economias na mesma linha. **Guardar** porque `recipes_for` varre o livro de receitas
        -- inteiro -- a propria API avisa que nao ha indice por item --, e a arvore perguntava de
        -- novo a cada no; num modpack com milhares de receitas isso sozinho estoura os 20 ms.
        --
        -- E guardar o **resultado**, e nao a receita crua: a resposta do jogo traz ate nove posicoes
        -- com ate trinta e duas alternativas cada, e o que a arvore precisa depois sao os poucos
        -- ingredientes escolhidos. Segurar a resposta inteira por item era carregar duas mil
        -- cadeias de texto para usar nove.
        --
        -- A escolha depende do estoque, que e lido uma vez e nao muda durante a arvore -- entao
        -- resolver uma vez por item esta certo.
        estado.receitas = estado.receitas or {}
        local resolvida = estado.receitas[item]

        if resolvida == nil then
            local receitas = receitas_de(ctx, item)
            if #receitas == 0 then
                -- `false` e nao `nil`: nil faria a proxima visita perguntar de novo, e "ninguem
                -- sabe fazer" e uma resposta tao cara de obter quanto qualquer outra.
                resolvida = false
            else
                local receita = receitas[1]
                resolvida = {
                    por_lote = receita.output ~= nil and tonumber(receita.output.count) or 1,
                    ingredientes = ingredientes_de(receita, estado.tem),
                }
            end
            estado.receitas[item] = resolvida
        end

        if resolvida == false then
            return doEstoque, "a rede nao tem " .. item .. " e ninguem sabe fazer", estado
        end

        porLote = resolvida.por_lote
        ingredientes = resolvida.ingredientes
    end

    if porLote < 1 then porLote = 1 end

    local lotes = math.ceil(falta / porLote)

    -- **Um lote por vez quando ha maquina no caminho.**
    --
    -- Sem este teto, pedir dezesseis carvoes mandava dezesseis troncos de uma vez para o slot que
    -- o mapa declarou como entrada. O `1x` do mapa era respeitado por lote, e o que ninguem
    -- limitava era quantos lotes a maquina recebia junto -- entao o slot inteiro enchia e a
    -- maquina ficava com material para dezesseis ciclos que ela nao ia executar, porque a rede
    -- pede o produto no mesmo tique.
    --
    -- Enquanto a fabricacao acontece toda num tique, mais de um lote por chamada nao produz mais
    -- nada: so tira da rede o que vai ficar parado dentro da maquina. Um lote e o que ela
    -- consegue fechar.
    -- E o teto vale so no pedido de cima, e nao nos passos que a receita deriva.
    --
    -- Cego, ele quebrava a propria cadeia que existe para funcionar: uma pederneira que precisa de
    -- dois cascalhos ficava com um, e a receita legitima morria com "falta cascalho". Quem
    -- despejava material na maquina era o jogador pedindo dezesseis; quantos cascalhos uma
    -- pederneira come nao e escolha de ninguem, e sim a receita.
    if maquina ~= nil and lotes > 1 and estado.profundidade == 0 then lotes = 1 end

    if #ingredientes == 0 then
        return doEstoque, "a receita de " .. item .. " nao lista ingrediente", estado
    end

    -- 3. Cada ingrediente e um pedido novo, pelas mesmas regras.
    estado.profundidade = estado.profundidade + 1
    for _, ingrediente in ipairs(ingredientes) do
        local precisa = ingrediente.count * lotes
        local atendido, motivo = planejar(ctx, nos, ingrediente.item, precisa, estado)

        if atendido < precisa then
            estado.profundidade = estado.profundidade - 1
            -- Um ramo que nao fecha derruba a fabricacao inteira, e de proposito: comecar e parar no
            -- meio consome os outros ingredientes e nao produz nada.
            return doEstoque, motivo or ("falta " .. ingrediente.item .. " para fazer " .. item), estado
        end
    end
    estado.profundidade = estado.profundidade - 1

    -- O plano do fundo para a raiz: quem usa vem depois de quem produz.
    estado.fabricar[#estado.fabricar + 1] = {
        item = item,
        lotes = lotes,
        por_lote = porLote,
        ingredientes = ingredientes,
        -- Presente so quando o resultado foi declarado: e por onde o produto tem que passar.
        maquina = maquina,
        -- E de qual cano veio, porque o mapa de slots da maquina mora nele: a mesma fornalha
        -- acoplada a dois canos pode ser entrada de um e saida do outro.
        cano = cano,
    }

    -- A sobra do ultimo lote fica disponivel para outro ramo -- e o que o original chama de extra.
    local produzido = lotes * porLote
    if produzido > falta then
        estado.reservado[item] = (estado.reservado[item] or 0) - (produzido - falta)
    end

    -- **O que foi planejado, e nao o que foi pedido.**
    --
    -- Com o teto de um lote acima, prometer a quantidade inteira seria mentir: quem pediu
    -- dezesseis recebe um, e o terminal precisa dizer um. Sem esta conta o pedido voltava dizendo
    -- "atendido" com o bau vazio, que e o pior desfecho de todos.
    local atendidoAqui = doEstoque + produzido
    if atendidoAqui > quantidade then atendidoAqui = quantidade end

    return atendidoAqui, nil, estado
end

--- Planeja a partir de um padrao montado a mao, e nao de uma receita escolhida pelo produto.
--
-- E a diferenca entre o cano de fabricacao do original e um botao de "faca isto": com o padrao, o
-- jogador decide **qual** receita usar. `planejar` pega `receitas[1]` do jogo, e para um item com
-- varias receitas -- tabua de seis madeiras diferentes, pedra de duas -- a primeira raramente e a
-- que a base tem material para fazer.
--
-- Quem diz o que sai e o jogo, por `crafting_result`: a mesma busca que a bancada faz. Um
-- casamento escrito aqui saberia so as receitas com formato, e ficaria devendo as de tag e as que
-- outro mod define em codigo.
local function planejar_padrao(ctx, nos, padrao, lotes)
    lotes = math.max(1, lotes or 1)

    local saida = ctx.server.crafting_result(padrao)
    if saida == nil then
        return 0, "esse arranjo nao faz nada", nil
    end

    local ingredientes = ingredientes_do_padrao(padrao)
    if #ingredientes == 0 then
        return 0, "o padrao esta vazio", nil
    end

    -- Os ingredientes viram pedidos comuns, pelas mesmas tres regras: o que existe, o que ja foi
    -- planejado, o que da para fabricar. E o que faz um padrao de bancada puxar a arvore inteira --
    -- pedir uma porta com o padrao certo derruba a arvore ate a tora.
    local estado = {
        reservado = {},
        tem = estoque_como_mapa(ctx, nos),
        fabricar = {},
        retirar = {},
        nos = 0,
        profundidade = 1,
    }

    for _, ingrediente in ipairs(ingredientes) do
        local precisa = ingrediente.count * lotes
        local atendido, motivo = planejar(ctx, nos, ingrediente.item, precisa, estado)

        if atendido < precisa then
            -- Um ramo que nao fecha derruba o pedido inteiro, e de proposito: comecar e parar no
            -- meio consome os outros ingredientes e nao produz nada.
            return 0, motivo or ("falta " .. ingrediente.item), nil
        end
    end

    -- O passo do proprio padrao vai por ultimo: quem usa vem depois de quem produz.
    estado.fabricar[#estado.fabricar + 1] = {
        item = saida.item,
        lotes = lotes,
        por_lote = saida.count,
        ingredientes = ingredientes,
        padrao = true,
    }

    return lotes * saida.count, nil, estado
end

--- Executa um plano ja resolvido.
--
-- Devolve quanto ficou pronto. Roda depois de `planejar`, e nao junto: separar as duas e o que
-- permite recusar um pedido inteiro sem ter consumido nada.
--
-- O fabricador nao usa uma bancada de verdade -- o loader nao tem API para isso. Ele consome os
-- ingredientes da rede e produz o resultado, o que da o mesmo efeito para quem joga e mantem a
-- conta honesta: nada aparece sem que o material tenha sumido.
local function executar(ctx, nos, plano, destino)
    -- **So a fila cheia recusa um pedido.**
    --
    -- Antes o guarda recusava qualquer pedido enquanto o cano esperasse alguma coisa, e isso era
    -- rigido demais: pedir cinco carvoes atendia um e recusava quatro. Uma maquina trabalhando em
    -- fila e o comportamento esperado, e nao um erro -- e o material dos pedidos recusados ja
    -- estava dentro dela, produzindo para ninguem recolher.
    --
    -- O guarda continua vindo antes de qualquer retirada: recusar depois de tirar da rede deixaria
    -- material picado no caminho, que e o defeito que este mod existe para nao ter.
    local espera = mod.import("lib/espera.lua")
    for _, passo in ipairs(plano.fabricar) do
        if passo.maquina ~= nil and passo.cano ~= nil
                and espera.cheio(ctx, passo.cano.x, passo.cano.y, passo.cano.z) then
            return 0, "a fila da maquina em " .. passo.maquina.x .. "," .. passo.maquina.y .. ","
                   .. passo.maquina.z .. " esta cheia; espere as " .. espera.MAX_FILA
                   .. " que ja estao nela"
        end
    end

    -- **Consome o que o plano reservou do estoque, e so isso.**
    --
    -- Os ingredientes intermediarios nao existem em lugar nenhum: as tabuas de uma bancada sao
    -- produzidas no passo anterior, e procura-las nos provedores devolve nada. A primeira versao
    -- tentava tirar cada ingrediente de cada passo e parava no meio com "o estoque mudou" -- depois
    -- de ja ter consumido uma tora. O plano ja separa as duas coisas: `retirar` e o que sai do
    -- mundo, e `fabricar` e o que se transforma no caminho.
    local tirado = {}

    for item, precisa in pairs(plano.retirar) do
        local total = 0

        for _, no in ipairs(nos) do
            if total >= precisa then break end
            if rede.e_provedor(no.bloco) then
                for _, fonte in ipairs(rede.inventarios_em(ctx, no)) do
                    if total >= precisa then break end
                    total = total + ctx.server.extract_from(
                            fonte.x, fonte.y, fonte.z, item, precisa - total)
                end
            end
        end

        tirado[item] = total
        if total < precisa then
            -- Alguem mexeu no bau entre planejar e executar. Devolve o que ja saiu, para nao ficar
            -- material picado espalhado -- e o defeito que este mod existe para nao ter.
            for devolver, quantidade in pairs(tirado) do
                if quantidade > 0 then
                    for _, no in ipairs(nos) do
                        if quantidade <= 0 then break end
                        if rede.e_provedor(no.bloco) then
                            for _, fonte in ipairs(rede.inventarios_em(ctx, no)) do
                                if quantidade <= 0 then break end
                                quantidade = ctx.server.insert_into(
                                        fonte.x, fonte.y, fonte.z, devolver, quantidade)
                            end
                        end
                    end
                end
            end
            return 0, "o estoque mudou no meio do pedido"
        end
    end

    -- O resultado sai no bau encostado em quem pediu.
    --
    -- E nao pela entrega da rede: aquela procura o item nos provedores, e o que acabou de ser feito
    -- nao esta em provedor nenhum. Pedir a rede para "entregar" algo que ela nao tem devolve zero.
    local raiz = plano.fabricar[#plano.fabricar]
    if raiz == nil then return 0, "nada a fabricar" end

    local alvo = rede.destino(ctx, destino)
    if alvo == nil then return 0, "sem bau encostado em quem pediu" end

    --- Faz um passo passar pela maquina acoplada, se houver uma.
    --
    -- Os ingredientes entram na maquina e o produto e retirado de la: o que nao sair, nao foi
    -- produzido. E o que separa "a rede sabe fazer isto" de "o jogador escreveu que sabe".
    --
    -- **A maquina fica com o material se nao produzir**, e isso e de proposito: e o que uma
    -- fornalha faz quando voce poe minerio e fecha a tela. O material nao volta, mas tambem nao
    -- vira produto -- e o defeito que importa evitar, item aparecendo, nao acontece.
    local function passar(passo)
        local esperado = passo.lotes * passo.por_lote
        if passo.maquina == nil then return esperado, nil end

        local maquina = mod.import("lib/maquina.lua")
        local cano = passo.cano or destino

        -- **Slot que nao existe nesta maquina e ignorado.**
        --
        -- O mapa mora no cano e sobrevive a troca da maquina: mapear um bau de 27 slots e depois
        -- pousar uma fornalha de 3 no lugar deixa um slot 4 apontando para o vazio. A ponte recusa
        -- -- com razao --, e a recusa vinha como erro de Lua no meio do pedido, que nao se parece
        -- nem um pouco com "o mapa e de outra maquina".
        local tamanho = ctx.server.container_size(passo.maquina.x, passo.maquina.y, passo.maquina.z)

        local function existe(slot)
            return slot ~= nil and slot >= 0 and slot < tamanho
        end

        for _, ingrediente in ipairs(passo.ingredientes) do
            local quantos = ingrediente.count * passo.lotes

            -- **O slot vem do mapa que o jogador desenhou.**
            --
            -- Sem ele, o carvao vai parar no slot do minerio e o minerio no do combustivel: quem
            -- escolhe e a maquina, e ela nao sabe o que a rede quis dizer. Sem mapa, o
            -- comportamento antigo -- deixar a maquina decidir -- continua valendo, e para um bau
            -- ele esta certo.
            -- **Enche um slot ate a conta dele, e so entao passa para o proximo.**
            --
            -- Antes ia tudo para um slot so: a busca devolvia um unico destino, escolhido com
            -- `pairs`, que nao tem ordem. Uma maquina com duas entradas do mesmo item ficava com
            -- uma cheia e a outra vazia, e qual das duas variava entre execucoes.
            local entradas = {}
            local foraDaMaquina = 0
            for _, entrada in ipairs(maquina.entradas_para(ctx, cano, ingrediente.item)) do
                if existe(entrada.slot) then
                    entradas[#entradas + 1] = entrada
                else
                    foraDaMaquina = foraDaMaquina + 1
                end
            end

            if foraDaMaquina > 0 then
                ctx.log.warn("LOGISTICA o mapa do cano em " .. cano.x .. "," .. cano.y .. ","
                             .. cano.z .. " cita " .. foraDaMaquina .. " slot(s) que a maquina em "
                             .. passo.maquina.x .. "," .. passo.maquina.y .. "," .. passo.maquina.z
                             .. " nao tem; ela so tem " .. tamanho)
                if ctx.player ~= nil then
                    ctx.player.send_message("LOGISTICA o mapa deste cano e de outra maquina: cita "
                            .. "slot que a atual nao tem. Use /mod logistica esquecer "
                            .. cano.x .. " " .. cano.y .. " " .. cano.z .. " e mapeie de novo")
                end
            end

            local naoCoube = quantos

            if #entradas == 0 then
                -- Sem mapa, a maquina decide -- o comportamento antigo, que para um bau esta certo.
                naoCoube = ctx.server.insert_into(passo.maquina.x, passo.maquina.y, passo.maquina.z,
                                                  ingrediente.item, quantos)
            else
                -- A divisao e aritmetica, e nao uma insercao por item: colocar de um em um seriam
                -- dezenas de escritas de inventario dentro dos 20 ms do callback. A conta decide
                -- tudo antes, e cada slot recebe a sua parte numa chamada so.
                local divisao, sobrando = maquina.distribuir(entradas, quantos, passo.lotes)
                naoCoube = sobrando

                for i, entrada in ipairs(entradas) do
                    if divisao[i] > 0 then
                        local sobra = ctx.server.insert_into(passo.maquina.x, passo.maquina.y,
                                                             passo.maquina.z,
                                                             ingrediente.item, divisao[i],
                                                             entrada.slot)
                        naoCoube = naoCoube + sobra
                    end
                end
            end

            -- **Material recusado interrompe a fabricacao.**
            --
            -- Enquanto isto era so um aviso, a maquina recusava o ingrediente e o passo seguinte
            -- puxava o produto assim mesmo -- tirando do estoque que ja estava la dentro e
            -- anunciando "FABRICOU". A rede perdia a pedra, a maquina perdia o cascalho e nada
            -- tinha sido feito: item aparecendo do nada, que e o defeito que esta camada existe
            -- para evitar. Parar aqui deixa o que ja entrou na maquina, como uma fornalha faz.
            if naoCoube > 0 then
                if ctx.player ~= nil then
                    ctx.player.send_message("LOGISTICA a maquina recusou " .. ingrediente.item
                            .. " -- confira se o slot de entrada esta ocupado com outra coisa")
                end
                ctx.log.warn("LOGISTICA a maquina em " .. passo.maquina.x .. ","
                             .. passo.maquina.y .. "," .. passo.maquina.z .. " nao aceitou "
                             .. naoCoube .. " x " .. ingrediente.item)
                return 0, "a maquina nao aceitou " .. ingrediente.item
                       .. " -- confira se o slot de entrada esta ocupado com outra coisa"
            end
        end

        -- E o produto sai do slot de saida, e nao de qualquer lugar: puxar sem slot tiraria de
        -- volta o proprio ingrediente que acabou de entrar.
        local saida = maquina.saida_para(ctx, cano, passo.item)
        if not existe(saida) then saida = nil end
        local saiu = ctx.server.extract_from(passo.maquina.x, passo.maquina.y, passo.maquina.z,
                                             passo.item, esperado, saida)

        -- **Produto que nao veio ainda nao e produto que nao vem.**
        --
        -- Uma fornalha nem acendeu quando a rede pede o resultado. Antes isso era um erro e o
        -- pedido morria com o material dentro da maquina; quem pediu clicava de novo e empilhava
        -- mais material que nunca virava nada. Agora o cano anota o que espera e confere a cada
        -- segundo, entregando quando ficar pronto.
        --
        -- So o passo final espera. Um passo do meio pendente pararia a cadeia com material ja
        -- retirado da rede para os passos seguintes, e retomar isso exige guardar o plano inteiro
        -- -- que e trabalho de outra ordem. Ate la, cadeia com maquina lenta no meio continua
        -- dizendo que nao deu.
        if saiu <= 0 then
            if passo == plano.fabricar[#plano.fabricar] then
                mod.import("lib/espera.lua").marcar(ctx, cano, passo.maquina,
                                                    passo.item, esperado, alvo)
                return 0, "a maquina esta processando " .. passo.item
                       .. "; o cano entrega quando ficar pronto"
            end
            return 0, "a maquina recebeu o material e ainda nao devolveu " .. passo.item
        end
        return saiu, nil
    end

    -- **Todo passo e executado, e nao so o ultimo.**
    --
    -- Enquanto so a raiz passava pela maquina, uma cadeia de duas maquinas anunciava "FABRICOU em
    -- 2 passo(s)" tendo usado uma: a pedra sumia da rede, a pederneira saia do estoque da segunda
    -- maquina, e a primeira nunca era tocada. Pedra virava pederneira de graca, com o log dizendo
    -- que tinha dado certo.
    --
    -- A lista ja vem do fundo para a raiz -- quem produz antes de quem usa --, entao percorre-la
    -- em ordem e o suficiente: o cascalho que sai da primeira maquina e o que entra na segunda.
    local produzido
    for _, passo in ipairs(plano.fabricar) do
        local saiu, erro = passar(passo)
        if erro ~= nil then return 0, erro end
        produzido = saiu
    end

    local sobrou = ctx.server.insert_into(alvo.x, alvo.y, alvo.z, raiz.item, produzido)

    -- **Um registro por fabricacao, dizendo o que entrou e o que saiu.**
    --
    -- Ate aqui fabricar era mudo: o material sumia do bau, o produto aparecia no outro, e nao havia
    -- como saber se a rede tinha feito alguma coisa ou se nada tinha acontecido. Num sistema que
    -- decide sozinho, "esta funcionando?" precisa de resposta.
    local consumido = {}
    for item, quantidade in pairs(plano.retirar) do
        consumido[#consumido + 1] = quantidade .. "x" .. item
    end
    table.sort(consumido)

    if ctx.player ~= nil then
        ctx.player.send_message("LOGISTICA fabricou " .. (produzido - sobrou) .. " x "
                                .. raiz.item .. " em " .. #plano.fabricar .. " passo(s)")
    end

    ctx.log.info("LOGISTICA FABRICOU " .. (produzido - sobrou) .. " x " .. raiz.item
                 .. " em " .. #plano.fabricar .. " passo(s)"
                 .. "; consumiu " .. (#consumido > 0 and table.concat(consumido, ", ") or "nada")
                 .. "; entregue em " .. alvo.x .. "," .. alvo.y .. "," .. alvo.z)

    if sobrou > 0 then
        return produzido - sobrou, "o bau encheu; " .. sobrou .. " nao coube"
    end
    return produzido, nil
end

return {
    executar = executar,
    planejar_padrao = planejar_padrao,
    ingredientes_do_padrao = ingredientes_do_padrao,
    PROFUNDIDADE = PROFUNDIDADE,
    MAX_NOS = MAX_NOS,
    receitas_de = receitas_de,
    ingredientes_de = ingredientes_de,
    planejar = planejar,
}
