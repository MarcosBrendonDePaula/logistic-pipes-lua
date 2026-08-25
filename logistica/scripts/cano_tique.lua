-- O tique agendado de um cano: mover as cargas que estao nele.
--
-- Os tres blocos apontam para este mesmo arquivo. Um cano, um provedor e um terminal transportam do
-- mesmo jeito -- o que os diferencia e de onde o item entra e onde ele sai, e isso ja esta decidido
-- na rota antes de a viagem comecar.

local viagem = mod.import("lib/viagem.lua")

return function(ctx)
    viagem.passo(ctx, ctx.block.x, ctx.block.y, ctx.block.z)
end
