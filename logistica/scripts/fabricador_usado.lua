-- Clicar num fabricador abre a configuracao da maquina acoplada.
--
-- **E nao a bancada 3x3.** Com uma maquina do lado, o padrao e o slot de resultado declaram a mesma
-- coisa que o mapa de entradas e saidas -- em outro lugar e com outra forma. Duas telas dizendo o
-- mesmo confundem, e a que fala da maquina e a que serve para qualquer maquina.
--
-- A bancada continua existindo, atras de um botao, porque ela e o unico jeito de definir uma receita
-- **sem maquina**: duas tabuas empilhadas fazem vara, e nenhum bloco precisa estar do lado.

local tela_maquina = mod.import("lib/tela_maquina.lua")

return function(ctx)
    tela_maquina.abrir(ctx, ctx.block.x, ctx.block.y, ctx.block.z)

    -- Devolver false cancela a acao padrao do jogo: sem isso, clicar com um bloco na mao tambem
    -- colocaria o bloco.
    return false
end
