-- Clicar num satelite diz o nome dele.
--
-- Dar nome ainda e pelo comando: um campo de texto exige tela desenhada, e a do terminal ja e a
-- parte mais cara deste mod. Ler pelo clique cobre o que mais se precisa no dia a dia -- descobrir
-- qual satelite e este sem ir ate o computador.

local abastecimento = mod.import("lib/abastecimento.lua")

return function(ctx)
    local nome = abastecimento.nome_do_satelite(ctx, ctx.block.x, ctx.block.y, ctx.block.z)

    if nome == nil then
        ctx.player.send_message("Satelite sem nome. Use /mod logistica satelite "
                                .. ctx.block.x .. " " .. ctx.block.y .. " " .. ctx.block.z .. " <nome>")
    else
        ctx.player.send_message("Satelite: " .. nome)
    end
    return false
end
