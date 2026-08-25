-- Clicar num fabricador diz o que a rede sabe fazer a partir dali.
--
-- Ele nao guarda receita: usa as do proprio jogo. Um fabricador que so soubesse fazer o que o mod
-- ensinou seria inutil num modpack, onde quase tudo vem de outro lugar.

local rede = mod.import("lib/rede.lua")

return function(ctx)
    local nos = rede.varrer(ctx, ctx.block.x, ctx.block.y, ctx.block.z)
    local itens = rede.estoque(ctx, nos)

    ctx.player.send_message("Fabricador: a rede tem " .. #itens .. " item(ns) em estoque.")
    ctx.player.send_message("Use /mod logistica fabricar " .. ctx.block.x .. " " .. ctx.block.y
                            .. " " .. ctx.block.z .. " <item> [quantidade]")
    return false
end
