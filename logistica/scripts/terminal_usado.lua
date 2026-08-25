-- Clicar no terminal abre a tela.
--
-- O comportamento de bloco aponta um arquivo, e o arquivo devolve uma funcao -- e nao o nome de uma
-- funcao do main.lua. Sao dois caminhos diferentes de proposito: um bloco pode ter logica propria
-- sem que o entrypoint precise conhecer cada um deles.
--
-- Devolver false cancela a acao padrao do jogo. Importa quando o jogador esta com um bloco na mao:
-- sem o cancelamento, clicar no terminal tambem colocaria o bloco que ele estivesse segurando.

local terminal = mod.import("lib/terminal.lua")

return function(ctx)
    return terminal.abrir(ctx)
end
