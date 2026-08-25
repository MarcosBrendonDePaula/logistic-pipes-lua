-- Uma rede de canos que encontra e entrega itens, no espirito do Logistic Pipes.
--
-- O original tem dezenas de canos; este porte fica nos tres que formam o ciclo completo, que sao os
-- que a descricao do proprio mod chama de:
--
--   Cano Logistico   -- "routes items around the network"
--   Cano Provedor    -- "attaches to an inventory, sends 16 items into the network on request"
--   Terminal         -- "lets you manually request items... put a chest on the pipe to catch items"
--
-- A ideia central e essa: o terminal pergunta a rede o que existe, voce escolhe, e o provedor tira
-- do bau ao lado dele e manda para o bau ao lado do terminal. Tudo o mais do mod original --
-- crafting, satelite, chassi, modulos -- e construido em cima disso.
--
-- Por que portar um mod que parou.
--
-- O Logistic Pipes nao parou por falta de ideia: acompanhar as versoes do Minecraft em Java custa
-- caro, porque cada atualizacao mexe em registro, em renderizacao e em rede. Um mod declarativo nao
-- paga esse preco -- quem acompanha a versao e o loader, e o mod continua sendo o mesmo JSON e o
-- mesmo Lua. E a razao de este exemplo existir aqui em vez de ser so uma demonstracao.
--
-- Ele tambem e um teste de esforco: usa bloco declarado, inventario de terceiros, modulo, estado
-- por jogador e tela de uma vez so. O que faltar na API aparece aqui antes de aparecer para quem
-- escreve um mod de verdade.

local terminal = mod.import("lib/terminal.lua")
local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")
local abastecimento = mod.import("lib/abastecimento.lua")
local viagem = mod.import("lib/viagem.lua")

mod.screen("terminal", terminal.evento)

-- Um comando para conferir a rede sem estar no jogo.
--
-- O terminal abre por clique, e clique exige alguem no mundo. Isso deixaria a rede sem nenhuma
-- verificacao automatica -- e e justamente a parte que mais tem como quebrar em silencio. O
-- comando faz as mesmas perguntas que a tela faz, e responde no log.
--
--   /mod logistica ver <x> <y> <z>                        o que a rede enxerga dali
--   /mod logistica pedir <x> <y> <z> <item>               entrega, como o botao da tela faria
--   /mod logistica satelite <x> <y> <z> <nome>            da nome a um satelite
--   /mod logistica abastecer <x> <y> <z> <item> <qtd>     mantem um bau em estoque
mod.command("logistica", function(ctx)
    local args = ctx.argv or {}
    local acao = ctx.subcommand or "ver"

    local x = tonumber(args[2])
    local y = tonumber(args[3])
    local z = tonumber(args[4])

    if x == nil or y == nil or z == nil then
        ctx.log.warn("uso: /mod logistica ver|pedir|satelite|abastecer <x> <y> <z> [...]")
        return
    end

    -- Configurar um satelite ou um abastecedor nao precisa varrer a rede: os dois so escrevem na
    -- posicao do proprio cano.
    if acao == "satelite" then
        local nome = args[5]
        if nome == nil then
            ctx.log.warn("uso: /mod logistica satelite <x> <y> <z> <nome>")
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:satelite" then
            ctx.log.warn("LOGISTICA nao ha satelite em " .. x .. "," .. y .. "," .. z)
            return
        end
        abastecimento.nomear_satelite(ctx, x, y, z, nome)
        ctx.log.info("LOGISTICA satelite=" .. nome .. " em " .. x .. "," .. y .. "," .. z)
        return
    end

    if acao == "abastecer" then
        local item = args[5]
        local alvo = tonumber(args[6])
        if item == nil or alvo == nil then
            ctx.log.warn("uso: /mod logistica abastecer <x> <y> <z> <item> <quantidade>")
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:abastecedor" then
            ctx.log.warn("LOGISTICA nao ha abastecedor em " .. x .. "," .. y .. "," .. z)
            return
        end
        abastecimento.configurar_abastecedor(ctx, x, y, z, item, alvo)
        ctx.log.info("LOGISTICA abastecedor=" .. item .. " alvo=" .. alvo)
        return
    end

    local nos, cortou = rede.varrer(ctx, x, y, z)
    local lista = rede.estoque(ctx, nos)

    if acao == "pedir" then
        local item = args[5]
        if item == nil then
            ctx.log.warn("falta o item: /logistica pedir <x> <y> <z> <item>")
            return
        end

        local entregue, motivo = viagem.entregar(ctx, nos, { x = x, y = y, z = z },
                                               item, rede.POR_PEDIDO)
        ctx.log.info("LOGISTICA entregue=" .. entregue .. " item=" .. item
                     .. " motivo=" .. tostring(motivo))
        return
    end

    ctx.log.info("LOGISTICA canos=" .. #nos .. " itens=" .. #lista
                 .. (cortou and " (rede cortada no teto)" or ""))
    for _, entrada in ipairs(lista) do
        ctx.log.info("LOGISTICA  " .. entrada.item .. " x" .. entrada.count)
    end
end)

local function on_loader_ready(ctx)
    ctx.log.info("Logistica pronta: use o Terminal Logistico com um bau encostado nele.")
end

return {
    on_loader_ready = on_loader_ready,
}
