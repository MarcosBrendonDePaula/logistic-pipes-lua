-- A tela de mapeamento da maquina acoplada.
--
-- **Por que uma tela desenhada, e nao uma janela de container.** A distincao que esta sessao pagou
-- caro para aprender: janela de container serve para MEXER EM ITEM -- arrastar, shift-clique, o
-- item no cursor. Aqui nao se move nada: diz-se o que cada slot da maquina *significa*. Isso e
-- mostrar dados e receber clique, que e exatamente o que a tela desenhada faz bem.
--
-- **A grade mostra, o modal decide.** Os slots aparecem como a maquina os tem, e clicar num deles
-- abre as opcoes daquele slot por cima. Girar o papel num botao por linha funcionava e nao escala:
-- numa maquina de vinte slots a lista some da tela, e nao ha onde por o filtro.
--
-- O modal e um painel desenhado por cima, na mesma tela -- e nao outra tela. Trocar de tela perderia
-- o contexto e faria o "voltar" precisar de estado proprio; aqui basta esquecer qual slot estava
-- sendo editado.

local rede = mod.import("lib/rede.lua")
local maquina = mod.import("lib/maquina.lua")

local LARGURA = 256
local ALTURA = 244

-- Cores como TEXTO, e nao como numero: o loader recusa numero, e a recusa derruba a montagem da
-- tela inteira -- em silencio, porque um erro de Lua num callback e registrado e nao propagado.
local COR_TEXTO = "#E8E8E8FF"
local COR_FRACA = "#909090FF"
local COR_AVISO = "#FFD060FF"
local COR_ENTRADA = "#80C0FFFF"
local COR_SAIDA = "#80E080FF"

local CELULA = 22
local COLUNAS = 9

local function quadro(ctx)
    ctx.state.maquinas = ctx.state.maquinas or {}
    local uuid = ctx.player and ctx.player.uuid or "console"
    ctx.state.maquinas[uuid] = ctx.state.maquinas[uuid] or { aviso = "" }
    return ctx.state.maquinas[uuid]
end

local function cor_do_papel(papel)
    if papel == "entrada" then return COR_ENTRADA end
    if papel == "saida" then return COR_SAIDA end
    return COR_FRACA
end

local function marca_do_papel(papel)
    if papel == "entrada" then return "E" end
    if papel == "saida" then return "S" end
    return ""
end

--- O slot que esta sendo editado, ou nil.
local function em_edicao(estado)
    if estado.editando == nil then return nil end
    for _, s in ipairs(estado.slots or {}) do
        if s.slot == estado.editando then return s end
    end
    return nil
end

--- O painel de opcoes de um slot, desenhado por cima da grade.
local function modal(elementos, s, mochila)
    local x, y = 16, 40
    local w, h = LARGURA - 32, ALTURA - 56

    elementos[#elementos + 1] = { layer = 1, type = "panel", x = x, y = y, w = w, h = h, style = "vanilla" }
    elementos[#elementos + 1] = { layer = 1, type = "panel", x = x + 8, y = y + 8, w = 18, h = 18,
                                  style = "slot" }
    if s.item ~= nil then
        elementos[#elementos + 1] = { layer = 1, type = "item", x = x + 9, y = y + 9,
                                      item = s.item, count = s.count }
    end

    elementos[#elementos + 1] = { layer = 1, type = "label", x = x + 32, y = y + 10, color = COR_TEXTO,
                                  text = "Slot " .. s.slot }
    elementos[#elementos + 1] = { layer = 1, type = "label", x = x + 32, y = y + 20, color = COR_FRACA,
                                  text = s.item and string.gsub(s.item, "^minecraft:", "")
                                         or "vazio" }

    -- Tres botoes, e nao um que gira: com espaco sobrando, ver as tres opcoes de uma vez e dizer
    -- qual e a atual custa menos que descobrir a ordem do giro.
    local papeis = { "entrada", "saida", "nenhum" }
    local bx = x + 8
    for _, papel in ipairs(papeis) do
        elementos[#elementos + 1] = { layer = 1, type = "button", id = "papel:" .. papel,
                                      x = bx, y = y + 34, w = 52, h = 18,
                                      text = (s.papel == papel and "[" .. papel .. "]") or papel }
        bx = bx + 56
    end

    -- O filtro so faz sentido num slot com papel: dizer "so ferro" onde nada entra nem sai nao muda
    -- nada, e um botao que nao muda nada e pior que um botao ausente.
    if s.papel == "nenhum" then
        elementos[#elementos + 1] = { layer = 1, type = "button", id = "voltar",
                                      x = x + w - 60, y = y + h - 24, w = 52, h = 18,
                                      text = "Voltar" }
        return
    end

    elementos[#elementos + 1] = { layer = 1, type = "label", x = x + 8, y = y + 58, color = COR_TEXTO,
                                  text = s.filtro
                                         and ((s.quantidade or 1) .. "x "
                                              .. string.gsub(s.filtro, "^minecraft:", ""))
                                         or "aceita qualquer item" }
    if s.filtro ~= nil then
        -- **O liberar desceu para a fileira de baixo, junto do Voltar.**
        --
        -- Onde ele estava, comecava em x+148 e o primeiro botao de quantidade ia ate x+150: os
        -- dois se sobrepunham, e o de cima ficava inalcancavel. Embaixo ele fica com os outros
        -- botoes de sair da edicao, que e o grupo a que pertence.
        elementos[#elementos + 1] = { layer = 1, type = "button", id = "liberar",
                                      x = x + w - 124, y = y + h - 24, w = 58, h = 18,
                                      text = "liberar" }

        -- **Quanto passa por este slot.**
        --
        -- Sem isso o mapa so sabia dizer "um de cada", e toda receita que nao fosse um para um
        -- ficava fora do alcance -- oito tabuas para um bau, duas para um bastao. Botoes e nao
        -- campo de texto porque o numero e pequeno, e escolher e mais rapido que digitar.
        elementos[#elementos + 1] = { layer = 1, type = "button", id = "qtd:-1",
                                      x = x + 130, y = y + 54, w = 20, h = 18, text = "-" }
        elementos[#elementos + 1] = { layer = 1, type = "button", id = "qtd:1",
                                      x = x + 152, y = y + 54, w = 20, h = 18, text = "+" }
        elementos[#elementos + 1] = { layer = 1, type = "button", id = "qtd:8",
                                      x = x + 174, y = y + 54, w = 26, h = 18, text = "+8" }
    end

    -- **O inventario do jogador, para escolher o filtro.**
    --
    -- Foi o buraco que a tela desenhada tinha: sem ele, o filtro so podia sair do item que ja
    -- estivesse no slot da maquina -- e um slot vazio nao tinha como ser configurado. A tela nao
    -- pode MOVER item, mas nao precisa: apontar basta.
    elementos[#elementos + 1] = { layer = 1, type = "label", x = x + 8, y = y + 76, color = COR_FRACA,
                                  text = "clique num item seu para travar este slot nele" }

    elementos[#elementos + 1] = { layer = 1, type = "panel", x = x + 7, y = y + 87,
                                  w = 9 * 18 + 2, h = 4 * 18 + 2, style = "slot" }
    elementos[#elementos + 1] = { layer = 1, type = "grid", id = "mochila", x = x + 8, y = y + 88,
                                  columns = 9, cell = 18, items = mochila }

    elementos[#elementos + 1] = { layer = 1, type = "button", id = "voltar",
                                  x = x + w - 60, y = y + h - 24, w = 52, h = 18, text = "Voltar" }
end

local function desenhar(ctx, estado)
    local elementos = {}
    local slots = estado.slots or {}

    elementos[#elementos + 1] = { type = "panel", x = 0, y = 0,
                                  w = LARGURA, h = ALTURA, style = "vanilla" }

    -- **Com o modal aberto, so o modal e desenhado.**
    --
    -- Nao e escolha estetica: botao e widget do jogo, desenhado depois de todos os elementos e fora
    -- da camada deles. Um painel por cima esconderia os botoes do proprio modal, e deixar os de
    -- baixo visiveis os manteria clicaveis atraves dele -- clicar "Fechar" sem ver que clicou.
    --
    -- Desenhar so o de cima resolve os dois de uma vez, e e o que uma janela modal e de verdade:
    -- enquanto ela esta aberta, o resto nao existe.
    local editando = em_edicao(estado)
    if editando ~= nil then
        -- A ordem das celulas e a que o jogador ve no inventario dele: as tres fileiras de cima
        -- primeiro (slots 9 a 35) e a barra embaixo (0 a 8). Listar por numero de slot poria a
        -- barra em cima, e o desenho nao bateria com o inventario que ele acabou de fechar.
        local mochila = {}
        for celula = 1, 36 do mochila[celula] = false end

        for _, entrada in ipairs(estado.mochila or {}) do
            local celula
            if entrada.slot >= 9 and entrada.slot <= 35 then
                celula = entrada.slot - 8
            elseif entrada.slot >= 0 and entrada.slot <= 8 then
                celula = 28 + entrada.slot
            end
            if celula ~= nil then
                mochila[celula] = { item = entrada.item, count = entrada.count }
            end
        end

        modal(elementos, editando, mochila)
        return { title = "Slots da Maquina", width = LARGURA, height = ALTURA,
                 elements = elementos }
    end

    elementos[#elementos + 1] = { type = "label", x = 10, y = 8, color = COR_TEXTO,
                                  text = (estado.nome or "maquina") .. " -- " .. #slots .. " slot(s)" }
    elementos[#elementos + 1] = { type = "label", x = 10, y = 20, color = COR_FRACA,
                                  text = "clique num slot para dizer o que ele e" }

    -- **Os slots onde a maquina os desenha.**
    --
    -- A posicao vem da tela da propria maquina, quando ela tem uma: a fornalha em L, o moedor do
    -- jeito dele. O jogador reconhece a maquina pela forma, e contar posicoes numa fileira para
    -- saber qual e qual e trabalho que a forma dispensa.
    --
    -- Cada slot e uma grade de uma celula so: e o unico elemento interativo que desenha item sem
    -- moldura de botao, e assim cada um pode ficar numa posicao arbitraria.
    local temDesenho = #slots > 0 and slots[1].x ~= nil
    local baseY = 34
    local fundo = 0

    for indice, s in ipairs(slots) do
        local px, py
        if temDesenho and s.x ~= nil then
            -- O desenho da maquina comeca no canto dela; aqui ele entra deslocado para caber
            -- abaixo do cabecalho.
            px = 10 + s.x
            py = baseY + s.y
        else
            -- Sem desenho, a fileira de sempre.
            local coluna = (indice - 1) % COLUNAS
            local linha = math.floor((indice - 1) / COLUNAS)
            px = 10 + coluna * CELULA
            py = baseY + 2 + linha * CELULA
        end
        fundo = math.max(fundo, py + 18)

        elementos[#elementos + 1] = { type = "panel", x = px - 1, y = py - 1, w = 20, h = 20,
                                      style = "slot" }
        -- **O filtro aparece como fantasma quando o slot esta vazio.**
        --
        -- Sem isso, escolher "so ferro" num slot vazio nao mudava nada na tela: a grade so mostrava
        -- o que estava fisicamente na maquina, e a decisao ficava invisivel exatamente onde ela
        -- precisa ser vista.
        local desenho = s.item and { item = s.item, count = s.count }
                        or (s.filtro and { item = s.filtro, count = 1 })
                        or false

        elementos[#elementos + 1] = { type = "grid", id = "slot:" .. s.slot, x = px, y = py,
                                      columns = 1, cell = 18, items = { desenho } }

        -- A marca do papel por cima: sem ela a tela mostra o conteudo e esconde justamente o que se
        -- veio configurar.
        if s.papel ~= "nenhum" then
            elementos[#elementos + 1] = { type = "label", x = px + 12, y = py + 10,
                                          color = cor_do_papel(s.papel),
                                          text = marca_do_papel(s.papel) }
        end
    end

    if #slots == 0 then
        elementos[#elementos + 1] = { type = "label", x = 10, y = 44, color = COR_AVISO,
                                      text = "nenhuma maquina encostada neste cano" }

        -- **A bancada so aparece quando e a unica saida.**
        --
        -- Com maquina do lado, o padrao 3x3 e o slot de resultado declaram a mesma coisa que o mapa
        -- de entradas e saidas -- duas telas dizendo o mesmo confundem. Sem maquina, a bancada e o
        -- unico jeito de definir uma receita: duas tabuas empilhadas fazem vara, e nenhum bloco
        -- precisa estar do lado.
        elementos[#elementos + 1] = { type = "label", x = 10, y = 58, color = COR_FRACA,
                                      text = "encoste uma maquina, ou monte a receita a mao:" }
        elementos[#elementos + 1] = { type = "button", id = "bancada", x = 10, y = 74,
                                      w = 120, h = 20, text = "Bancada 3x3" }
    else
        local y = math.min(fundo + 6, ALTURA - 56)
        elementos[#elementos + 1] = { type = "label", x = 10, y = y, color = COR_ENTRADA,
                                      text = "E = entrada" }
        elementos[#elementos + 1] = { type = "label", x = 90, y = y, color = COR_SAIDA,
                                      text = "S = saida" }
    end

    if estado.aviso ~= "" then
        elementos[#elementos + 1] = { type = "label", x = 10, y = ALTURA - 44,
                                      color = COR_AVISO, text = estado.aviso }
    end

    elementos[#elementos + 1] = { type = "button", id = "fechar", x = LARGURA - 70,
                                  y = ALTURA - 28, w = 60, h = 20, text = "Fechar" }

    return { title = "Slots da Maquina", width = LARGURA, height = ALTURA, elements = elementos }
end

--- Le a maquina acoplada e o mapa atual.
local function ler(ctx, estado)
    local acoplada = rede.inventarios_em(ctx, estado.cano)[1]

    estado.maquina = acoplada
    if acoplada == nil then
        estado.slots = {}
        estado.nome = nil
        return
    end

    estado.nome = ctx.server.get_block(acoplada.x, acoplada.y, acoplada.z)
    estado.slots = maquina.listar(ctx, estado.cano, acoplada)

    -- O inventario do jogador, para o modal poder oferecer o filtro. Lido junto do resto: a tela
    -- so redesenha por clique, e uma leitura a mais por clique nao pesa.
    estado.mochila = ctx.player.inventory()
end

local function evento(ctx)
    if ctx.player == nil then return end

    local estado = quadro(ctx)
    if estado.cano == nil then return end

    local acao = ctx.ui.action
    local elemento = ctx.ui.element or ""

    if acao == "close" then return end
    if acao ~= "click" then return end

    local editando = em_edicao(estado)

    if elemento == "fechar" then
        ctx.player.close_screen()
        return

    elseif elemento == "bancada" then
        -- A janela de itens do proprio bloco, aberta pelo script. Ela substitui esta tela, e fechar
        -- aquela volta ao jogo -- nao ha "voltar" porque nao ha pilha de telas no protocolo.
        ctx.player.open_block_inventory(estado.cano.x, estado.cano.y, estado.cano.z)
        return

    elseif string.sub(elemento, 1, 5) == "slot:" then
        -- Cada slot e a propria grade, entao o id ja diz qual e -- nao ha indice para traduzir, e
        -- por isso a posicao arbitraria nao complica o clique.
        estado.editando = tonumber(string.sub(elemento, 6))
        estado.aviso = ""

    elseif elemento == "voltar" then
        estado.editando = nil

    elseif string.sub(elemento, 1, 6) == "papel:" and editando ~= nil then
        -- Girar mantinha o filtro; escolher direto tambem mantem, pela mesma razao: trocar de
        -- entrada para saida sem redizer "so ferro" e o que se espera de um ajuste.
        local papel = string.sub(elemento, 7)
        local ok, erro = maquina.definir(ctx, estado.cano.x, estado.cano.y, estado.cano.z,
                                         editando.slot, papel, editando.filtro,
                                         editando.quantidade)
        estado.aviso = ok and "" or tostring(erro)

    elseif string.sub(elemento, 1, 4) == "qtd:" and editando ~= nil then
        local passo = tonumber(string.sub(elemento, 5)) or 0
        local quantos = (editando.quantidade or 1) + passo
        if quantos < 1 then quantos = 1 end
        if quantos > 64 then quantos = 64 end

        maquina.definir(ctx, estado.cano.x, estado.cano.y, estado.cano.z,
                        editando.slot, editando.papel, editando.filtro, quantos)
        estado.aviso = ""

    elseif elemento == "liberar" and editando ~= nil then
        maquina.definir(ctx, estado.cano.x, estado.cano.y, estado.cano.z,
                        editando.slot, editando.papel)
        estado.aviso = ""

    elseif elemento == "mochila" and editando ~= nil then
        -- O filtro vem do inventario do jogador, e nao do que estiver na maquina: um slot vazio
        -- tambem precisa poder ser configurado, e era justamente esse que ficava sem saida.
        local celula = tonumber(ctx.ui.value) or 0
        local slot
        if celula >= 1 and celula <= 27 then slot = celula + 8
        elseif celula >= 28 and celula <= 36 then slot = celula - 28 end

        local escolhido = nil
        if slot ~= nil then
            for _, entrada in ipairs(estado.mochila or {}) do
                if entrada.slot == slot then escolhido = entrada.item end
            end
        end

        if escolhido ~= nil then
            maquina.definir(ctx, estado.cano.x, estado.cano.y, estado.cano.z,
                            editando.slot, editando.papel, escolhido, editando.quantidade)
            estado.aviso = ""
        end
    end

    ler(ctx, estado)
    ctx.player.update_screen(desenhar(ctx, estado))
end

--- Abre a tela para o cano daquela posicao.
local function abrir(ctx, x, y, z)
    if ctx.player == nil then return end

    local estado = quadro(ctx)
    estado.cano = { x = x, y = y, z = z }
    estado.editando = nil
    estado.aviso = ""

    ler(ctx, estado)
    ctx.player.open_screen("maquina", desenhar(ctx, estado))
end

return {
    evento = evento,
    abrir = abrir,
}
