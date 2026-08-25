-- Clicar num abastecedor diz o que ele mantem, e quanto falta agora.

local abastecimento = mod.import("lib/abastecimento.lua")

return function(ctx)
    local x, y, z = ctx.block.x, ctx.block.y, ctx.block.z
    local config = abastecimento.configuracao(ctx, x, y, z)

    if config.item == nil then
        ctx.player.send_message("Abastecedor sem configuracao. Use /mod logistica abastecer "
                                .. x .. " " .. y .. " " .. z .. " <item> <quantidade>")
        return false
    end

    local no = { x = x, y = y, z = z, bloco = "logistica:abastecedor" }
    local falta = abastecimento.quanto_falta(ctx, no, config)

    ctx.player.send_message("Abastecedor: " .. config.item .. " ate " .. tostring(config.alvo)
                            .. (falta > 0 and (" -- faltam " .. falta) or " -- em dia"))
    return false
end
