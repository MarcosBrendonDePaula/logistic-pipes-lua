-- O tique agendado de um cano.
--
-- Os cinco blocos apontam para este arquivo, e ele decide pelo tipo. Um cano comum move as cargas
-- que estao nele; o abastecedor faz isso e ainda confere o bau que mantem em estoque.
--
-- Um arquivo por tipo seria mais arrumado e pior: todo cano transporta, entao a parte comum viraria
-- copia em cinco lugares.

local viagem = mod.import("lib/viagem.lua")
local abastecimento = mod.import("lib/abastecimento.lua")
local chassi = mod.import("lib/chassi.lua")

return function(ctx)
    local x, y, z = ctx.block.x, ctx.block.y, ctx.block.z

    viagem.passo(ctx, x, y, z)

    if ctx.block.id == "logistica:abastecedor" then
        abastecimento.conferir(ctx, x, y, z)
    elseif ctx.block.id == "logistica:chassi" then
        chassi.passo(ctx, x, y, z)
    end
end
