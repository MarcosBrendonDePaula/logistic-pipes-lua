-- A tela do terminal: o que a rede tem, e o pedido.
--
-- Fica num modulo porque duas partes precisam dela -- o main.lua, que registra o handler, e o
-- script de comportamento do bloco, que a abre ao clique. Duplicar daria duas telas que discordam
-- no primeiro ajuste.

local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")

local POR_PEDIDO = rede.POR_PEDIDO

-- ---------------------------------------------------------------- a tela

local LARGURA = 256
local ALTURA = 200
local POR_PAGINA = 7

-- Cores como TEXTO, e nao como numero.
--
-- O loader espera "#RRGGBB" ou "#RRGGBBAA"; um numero e recusado, e a recusa derruba a montagem da
-- tela inteira. O clique no terminal nao abria nada por causa disto, e o erro so aparecia no log --
-- um erro de Lua num callback e registrado, e nao propagado.
local COR_TEXTO = "#E8E8E8FF"
local COR_FRACA = "#909090FF"
local COR_AVISO = "#FFD060FF"

--- O estado da tela por jogador.
--
-- ctx.state e por mod, e nao por jogador: dois jogadores no mesmo terminal precisam de paginas
-- proprias, senao um vira a pagina do outro.
local function quadro(ctx)
    ctx.state.terminais = ctx.state.terminais or {}
    local uuid = ctx.player and ctx.player.uuid or "console"
    ctx.state.terminais[uuid] = ctx.state.terminais[uuid] or { pagina = 0, filtro = "", aviso = "" }
    return ctx.state.terminais[uuid]
end

local function desenhar(ctx, estado)
    local elementos = {}
    local lista = estado.estoque or {}

    -- O filtro roda sobre o que ja foi lido, e nao relendo a rede: varrer de novo a cada tecla
    -- digitada estouraria o orcamento do callback.
    if estado.filtro ~= "" then
        local filtrado = {}
        for _, entrada in ipairs(lista) do
            if string.find(entrada.item, estado.filtro, 1, true) then
                filtrado[#filtrado + 1] = entrada
            end
        end
        lista = filtrado
    end

    local paginas = math.max(1, math.ceil(#lista / POR_PAGINA))
    if estado.pagina >= paginas then estado.pagina = paginas - 1 end
    if estado.pagina < 0 then estado.pagina = 0 end

    elementos[#elementos + 1] = { type = "panel", x = 0, y = 0,
                                  w = LARGURA, h = ALTURA, style = "vanilla" }
    elementos[#elementos + 1] = { type = "label", x = 10, y = 8, color = COR_TEXTO,
                                  text = "Rede: " .. (estado.nos or 0) .. " cano(s), "
                                         .. #lista .. " item(ns)" }
    elementos[#elementos + 1] = { type = "input", id = "filtro", x = 10, y = 22,
                                  w = LARGURA - 20, h = 16, value = estado.filtro }

    local y = 44
    local de = estado.pagina * POR_PAGINA + 1
    local ate = math.min(de + POR_PAGINA - 1, #lista)

    for indice = de, ate do
        local entrada = lista[indice]
        elementos[#elementos + 1] = { type = "item", x = 10, y = y - 2,
                                      item = entrada.item, count = entrada.count }
        elementos[#elementos + 1] = { type = "label", x = 30, y = y, color = COR_TEXTO,
                                      text = entrada.item }
        elementos[#elementos + 1] = { type = "label", x = 30, y = y + 9, color = COR_FRACA,
                                      text = "na rede: " .. entrada.count }
        elementos[#elementos + 1] = { type = "button", id = "pedir:" .. entrada.item,
                                      x = LARGURA - 62, y = y - 1, w = 52, h = 18,
                                      text = "Pedir " .. POR_PEDIDO }
        y = y + 20
    end

    if #lista == 0 then
        elementos[#elementos + 1] = { type = "label", x = 10, y = 50, color = COR_FRACA,
                                      text = estado.filtro == ""
                                             and "Nenhum provedor com estoque na rede."
                                             or "Nada encontrado." }
    end

    if estado.aviso ~= "" then
        elementos[#elementos + 1] = { type = "label", x = 10, y = ALTURA - 44,
                                      color = COR_AVISO, text = estado.aviso }
    end

    if paginas > 1 then
        elementos[#elementos + 1] = { type = "button", id = "anterior", x = 10, y = ALTURA - 28,
                                      w = 22, h = 20, text = "<" }
        elementos[#elementos + 1] = { type = "label", x = 38, y = ALTURA - 22, color = COR_TEXTO,
                                      text = (estado.pagina + 1) .. "/" .. paginas }
        elementos[#elementos + 1] = { type = "button", id = "proxima", x = 62, y = ALTURA - 28,
                                      w = 22, h = 20, text = ">" }
    end

    elementos[#elementos + 1] = { type = "button", id = "atualizar", x = LARGURA - 148,
                                  y = ALTURA - 28, w = 72, h = 20, text = "Atualizar" }
    elementos[#elementos + 1] = { type = "button", id = "fechar", x = LARGURA - 70,
                                  y = ALTURA - 28, w = 60, h = 20, text = "Fechar" }

    return { title = "Terminal Logistico", width = LARGURA, height = ALTURA,
             elements = elementos }
end

--- Le a rede e guarda o retrato.
--
-- Guardado, e nao relido a cada desenho: a varredura e cara, e a tela redesenha a cada tecla. O
-- botao Atualizar existe justamente para quem sabe que a rede mudou.
local function ler_rede(ctx, estado)
    local pos = estado.terminal
    local nos, cortou = rede.varrer(ctx, pos.x, pos.y, pos.z)

    estado.nos = #nos
    estado.rede = nos
    estado.estoque = rede.estoque(ctx, nos)
    estado.aviso = cortou
            and ("rede grande demais; vendo so " .. rede.MAX_NOS .. " canos")
            or ""
end

local function evento(ctx)
    if ctx.player == nil then return end

    local estado = quadro(ctx)
    local acao = ctx.ui.action
    local elemento = ctx.ui.element or ""

    if acao == "close" then return end

    if elemento == "filtro" and (acao == "change" or acao == "submit") then
        estado.filtro = ctx.ui.value or ""
        estado.pagina = 0
    elseif acao ~= "click" then
        return
    elseif elemento == "fechar" then
        ctx.player.close_screen()
        return
    elseif elemento == "atualizar" then
        ler_rede(ctx, estado)
    elseif elemento == "anterior" then
        estado.pagina = estado.pagina - 1
    elseif elemento == "proxima" then
        estado.pagina = estado.pagina + 1
    elseif string.sub(elemento, 1, 6) == "pedir:" then
        local item = string.sub(elemento, 7)
        local entregue, motivo = viagem.entregar(ctx, estado.rede or {}, estado.terminal,
                                          item, POR_PEDIDO)

        -- O resultado tambem no log, e nao so no rodape da tela.
        --
        -- O aviso da tela e uma linha discreta embaixo de uma lista; quem clica olha para o item,
        -- nao para o rodape. Foi assim que "pedi e nao veio nada" ficou sem resposta por uma
        -- sessao inteira: o motivo estava escrito na tela o tempo todo, e nao havia como conferir
        -- depois. O log guarda.
        ctx.log.info("LOGISTICA pedido item=" .. item .. " entregue=" .. entregue
                     .. " motivo=" .. tostring(motivo))

        if entregue > 0 then
            estado.aviso = "entregue: " .. entregue .. " x " .. item
                           .. (motivo and (" (" .. motivo .. ")") or "")
        else
            estado.aviso = "nada entregue: " .. (motivo or "motivo desconhecido")
        end

        -- Reler depois de entregar: o estoque mudou, e mostrar o numero antigo faria alguem pedir
        -- de novo o que ja saiu.
        ler_rede(ctx, estado)
    end

    ctx.player.update_screen(desenhar(ctx, estado))
end

--- Abre o terminal. Chamado pelo comportamento do bloco.
local function abrir(ctx)
    if ctx.player == nil then return end

    local estado = quadro(ctx)
    estado.terminal = { x = ctx.block.x, y = ctx.block.y, z = ctx.block.z }
    estado.pagina = 0
    estado.aviso = ""

    ler_rede(ctx, estado)
    ctx.player.open_screen("terminal", desenhar(ctx, estado))
    return false
end


return {
    evento = evento,
    abrir = abrir,
}
