-- Clicar num fabricador abre a bancada dele.
--
-- Ele nao guarda receita declarada: usa as do proprio jogo, e quem escolhe qual e o padrao que o
-- jogador monta. Um fabricador que so soubesse fazer o que o mod ensinou seria inutil num modpack,
-- onde quase tudo vem de outro lugar.

local fabricador = mod.import("lib/fabricador.lua")

return function(ctx)
    return fabricador.abrir(ctx)
end
