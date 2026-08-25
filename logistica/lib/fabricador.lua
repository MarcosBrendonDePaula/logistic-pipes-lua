-- A tela do fabricador: montar o padrao na bancada, e ver o que sai antes de gastar material.
--
-- O motor mora em `fabricacao.lua`; aqui so ha a tela. A separacao nao e enfeite: a arvore de
-- pedido e testavel sem cliente, e os casos da bateria dependem disso.
--
-- **Por que um padrao, e nao um botao de "faca X".** `planejar` escolhe `receitas[1]` do jogo, e um
-- item com varias receitas -- tabua de seis madeiras, pedra de duas -- raramente tem como primeira
-- aquela que a base tem material para fazer. Com o padrao quem escolhe e o jogador, que e o que o
-- cano de fabricacao do original faz.
--
-- **A tela tem dois passos, e e de proposito.** Planejar e executar sao funcoes separadas porque um
-- pedido que descobre no meio que falta um ingrediente ja consumiu os outros. A tela expoe essa
-- separacao em vez de esconde-la: primeiro o plano, com o que sai do estoque e o que sera feito; so
-- entao o botao que consome.

local rede = mod.import("lib/rede.lua")
local fabricacao = mod.import("lib/fabricacao.lua")

local LARGURA = 256
local ALTURA = 210

-- Cores como TEXTO, e nao como numero.
--
-- O loader espera "#RRGGBB" ou "#RRGGBBAA"; um numero e recusado, e a recusa derruba a montagem da
-- tela inteira -- em silencio, porque um erro de Lua num callback e registrado e nao propagado.
local COR_TEXTO = "#E8E8E8FF"
local COR_FRACA = "#909090FF"
local COR_AVISO = "#FFD060FF"
local COR_BOA = "#80E080FF"

--- O padrao guardado no proprio bloco.
--
-- Em `block_data`, e nao numa tabela do mod: assim ele e gravado com o chunk e some junto com o
-- cano, em vez de ficar apontando para uma posicao que nao existe mais. E a mesma escolha que a
-- carga em viagem faz, pela mesma razao.
local function padrao_de(ctx, pos)
    local dados = ctx.server.get_block_data(pos.x, pos.y, pos.z)
    local padrao = dados.padrao or {}

    -- Normaliza para nove posicoes: o resto do codigo conta com isso, e um padrao curto vindo de
    -- uma versao anterior nao pode virar erro de indice dentro de um callback.
    for slot = 1, 9 do
        if padrao[slot] == nil then padrao[slot] = "" end
    end
    return padrao, dados
end

local function guardar_padrao(ctx, pos, padrao)
    local _, dados = padrao_de(ctx, pos)
    dados.padrao = padrao
    ctx.server.set_block_data(pos.x, pos.y, pos.z, dados)
end

--- O estado da tela por jogador.
--
-- `ctx.state` e por mod, e nao por jogador: dois jogadores no mesmo fabricador precisam de
-- rascunhos proprios, senao um planeja e o outro executa.
local function quadro(ctx)
    ctx.state.fabricadores = ctx.state.fabricadores or {}
    local uuid = ctx.player and ctx.player.uuid or "console"
    ctx.state.fabricadores[uuid] = ctx.state.fabricadores[uuid]
            or { item = "", lotes = 1, aviso = "", aviso_bom = false, plano = nil }
    return ctx.state.fabricadores[uuid]
end

--- O que aquele padrao produz, ou nil. Item desconhecido vira aviso, e nao queda.
local function resultado_de(ctx, padrao)
    local ok, saida = pcall(function() return ctx.server.crafting_result(padrao) end)
    if not ok then return nil, tostring(saida) end
    return saida, nil
end

local function desenhar(ctx, estado)
    local elementos = {}
    local padrao = estado.padrao or {}

    elementos[#elementos + 1] = { type = "panel", x = 0, y = 0,
                                  w = LARGURA, h = ALTURA, style = "vanilla" }
    elementos[#elementos + 1] = { type = "label", x = 10, y = 8, color = COR_TEXTO,
                                  text = "Rede: " .. (estado.nos or 0) .. " cano(s)" }

    -- A bancada. As celulas vazias entram como falso para o cliente desenhar o slot vazio: uma
    -- lista curta deslocaria tudo o que vem depois, e o padrao apareceria torto.
    local celulas = {}
    for slot = 1, 9 do
        local item = padrao[slot]
        celulas[slot] = (item ~= nil and item ~= "") and { item = item, count = 1 } or false
    end

    elementos[#elementos + 1] = { type = "grid", id = "bancada", x = 10, y = 24,
                                  columns = 3, cell = 20, items = celulas }

    -- O que sai, ao lado da bancada -- como na tela do jogo.
    elementos[#elementos + 1] = { type = "label", x = 86, y = 30, color = COR_FRACA, text = "=>" }

    if estado.saida ~= nil then
        elementos[#elementos + 1] = { type = "item", x = 106, y = 26,
                                      item = estado.saida.item, count = estado.saida.count }
        elementos[#elementos + 1] = { type = "label", x = 128, y = 30, color = COR_TEXTO,
                                      text = estado.saida.count .. " x " .. estado.saida.item }
    else
        elementos[#elementos + 1] = { type = "label", x = 106, y = 30, color = COR_FRACA,
                                      text = "esse arranjo nao faz nada" }
    end

    -- O item que o proximo clique na bancada coloca. Escrever e clicar e o gesto mais curto que o
    -- vocabulario de tela permite: nao ha como arrastar do inventario para uma grade.
    elementos[#elementos + 1] = { type = "label", x = 10, y = 92, color = COR_FRACA, text = "Por:" }
    elementos[#elementos + 1] = { type = "input", id = "item", x = 40, y = 90,
                                  w = LARGURA - 50, h = 16, value = estado.item }
    elementos[#elementos + 1] = { type = "label", x = 10, y = 110, color = COR_FRACA,
                                  text = "clique numa celula para por; vazio limpa" }

    local x = 10
    for _, lotes in ipairs({ 1, 8, 64 }) do
        elementos[#elementos + 1] = { type = "button", id = "lotes:" .. lotes,
                                      x = x, y = 126, w = 34, h = 18,
                                      text = (estado.lotes == lotes and "[" .. lotes .. "]")
                                             or tostring(lotes) }
        x = x + 38
    end
    elementos[#elementos + 1] = { type = "label", x = x + 4, y = 131, color = COR_FRACA,
                                  text = "lote(s)" }

    elementos[#elementos + 1] = { type = "button", id = "planejar", x = LARGURA - 132, y = 126,
                                  w = 60, h = 18, text = "Planejar" }

    -- O botao que consome so aparece com plano fechado. Um botao que esta la e recusa e pior que um
    -- botao ausente: quem clica fica sem saber se falhou ou se nao foi enviado.
    if estado.plano ~= nil then
        elementos[#elementos + 1] = { type = "button", id = "fabricar", x = LARGURA - 68, y = 126,
                                      w = 58, h = 18, text = "Fabricar" }
    end

    local y = 152
    if estado.plano ~= nil then
        elementos[#elementos + 1] = { type = "label", x = 10, y = y, color = COR_TEXTO,
                                      text = #estado.plano.fabricar .. " passo(s); sai do estoque:" }
        y = y + 12

        local mostrados = 0
        for item, quantidade in pairs(estado.plano.retirar) do
            if mostrados < 2 then
                elementos[#elementos + 1] = { type = "label", x = 10, y = y, color = COR_FRACA,
                                              text = "  " .. quantidade .. " x " .. item }
                y = y + 11
            end
            mostrados = mostrados + 1
        end
        if mostrados > 2 then
            elementos[#elementos + 1] = { type = "label", x = 10, y = y, color = COR_FRACA,
                                          text = "  e mais " .. (mostrados - 2) .. " item(ns)" }
        end
    end

    if estado.aviso ~= "" then
        elementos[#elementos + 1] = { type = "label", x = 10, y = ALTURA - 42,
                                      color = estado.aviso_bom and COR_BOA or COR_AVISO,
                                      text = estado.aviso }
    end

    elementos[#elementos + 1] = { type = "button", id = "limpar", x = 10, y = ALTURA - 28,
                                  w = 60, h = 20, text = "Limpar" }
    elementos[#elementos + 1] = { type = "button", id = "fechar", x = LARGURA - 70,
                                  y = ALTURA - 28, w = 60, h = 20, text = "Fechar" }

    return { title = "Fabricador", width = LARGURA, height = ALTURA, elements = elementos }
end

--- Le a rede e o padrao guardados no bloco.
local function ler(ctx, estado)
    local pos = estado.fabricador
    local nos, cortou = rede.varrer(ctx, pos.x, pos.y, pos.z)

    estado.nos = #nos
    estado.rede = nos
    estado.padrao = padrao_de(ctx, pos)
    estado.saida = resultado_de(ctx, estado.padrao)

    if cortou then
        estado.aviso = "rede grande demais; vendo so " .. rede.MAX_NOS .. " canos"
        estado.aviso_bom = false
    end
end

local function planejar(ctx, estado)
    estado.plano = nil
    estado.aviso_bom = false

    if estado.saida == nil then
        estado.aviso = "monte um arranjo que produza alguma coisa"
        return
    end

    -- Reler a rede antes de planejar: o estoque e a fonte da conta, e um retrato velho faria o
    -- plano prometer material que ja saiu do bau.
    ler(ctx, estado)

    local total, motivo, plano = fabricacao.planejar_padrao(
            ctx, estado.rede or {}, estado.padrao, estado.lotes)

    if total <= 0 then
        estado.aviso = "nao da: " .. tostring(motivo)
        return
    end

    estado.plano = plano
    estado.aviso = "plano pronto para " .. total .. " x " .. estado.saida.item
                   .. ". Nada foi consumido ainda."
    estado.aviso_bom = true
end

local function fabricar(ctx, estado)
    if estado.plano == nil then
        estado.aviso = "planeje antes de fabricar"
        estado.aviso_bom = false
        return
    end

    local pronto, erro = fabricacao.executar(
            ctx, estado.rede or {}, estado.plano, estado.fabricador)

    -- O plano vale uma vez: depois de executado o estoque mudou, e reaproveita-lo consumiria
    -- material contando com o que ja saiu.
    estado.plano = nil

    ctx.log.info("LOGISTICA fabricado padrao pronto=" .. pronto .. " motivo=" .. tostring(erro))

    if pronto > 0 then
        estado.aviso = "pronto: " .. pronto .. (erro and (" (" .. erro .. ")") or "")
        estado.aviso_bom = true
    else
        estado.aviso = "nada foi feito: " .. tostring(erro)
        estado.aviso_bom = false
    end

    ler(ctx, estado)
end

local function evento(ctx)
    if ctx.player == nil then return end

    local estado = quadro(ctx)
    local acao = ctx.ui.action
    local elemento = ctx.ui.element or ""

    if acao == "close" then return end

    if elemento == "item" and (acao == "change" or acao == "submit") then
        estado.item = ctx.ui.value or ""
    elseif acao ~= "click" then
        return
    elseif elemento == "bancada" then
        -- O clique numa grade traz o numero da celula, de um a nove. Zero significa que o clique
        -- caiu na borda, e ali nao ha o que fazer.
        local celula = tonumber(ctx.ui.value) or 0
        if celula >= 1 and celula <= 9 then
            estado.padrao[celula] = estado.item
            guardar_padrao(ctx, estado.fabricador, estado.padrao)

            local saida, erro = resultado_de(ctx, estado.padrao)
            estado.saida = saida
            -- O padrao mudou: o plano de antes produziria outra coisa que nao a que esta na tela.
            estado.plano = nil
            estado.aviso = erro or ""
            estado.aviso_bom = false
        end
    elseif elemento == "limpar" then
        for slot = 1, 9 do estado.padrao[slot] = "" end
        guardar_padrao(ctx, estado.fabricador, estado.padrao)
        estado.saida = nil
        estado.plano = nil
        estado.aviso = ""
    elseif elemento == "fechar" then
        ctx.player.close_screen()
        return
    elseif elemento == "planejar" then
        planejar(ctx, estado)
    elseif elemento == "fabricar" then
        fabricar(ctx, estado)
    elseif string.sub(elemento, 1, 6) == "lotes:" then
        estado.lotes = tonumber(string.sub(elemento, 7)) or 1
        estado.plano = nil
        estado.aviso = ""
    end

    ctx.player.update_screen(desenhar(ctx, estado))
end

--- Abre o fabricador. Chamado pelo comportamento do bloco.
local function abrir(ctx)
    if ctx.player == nil then return end

    local estado = quadro(ctx)
    estado.fabricador = { x = ctx.block.x, y = ctx.block.y, z = ctx.block.z }
    estado.plano = nil
    estado.aviso = ""
    estado.aviso_bom = false

    ler(ctx, estado)
    ctx.player.open_screen("fabricador", desenhar(ctx, estado))

    -- Devolver false cancela a acao padrao do jogo: sem isso, clicar no fabricador com um bloco na
    -- mao tambem colocaria o bloco.
    return false
end

return {
    evento = evento,
    abrir = abrir,
}
