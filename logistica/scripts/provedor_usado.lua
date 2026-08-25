-- Clicar num provedor abre a tela da rede.
--
-- A mesma do terminal, e nao uma tela propria: quem clica num cano quer ver o que a rede tem, e
-- duas telas com a mesma lista divergiriam no primeiro ajuste.
--
-- A diferenca esta em para onde o pedido vai: o destino e o bau encostado em quem foi clicado.
-- Pedir de um provedor entrega no bau dele -- e se for o mesmo bau que ja tem o item, o pedido e
-- recusado, porque o item sairia e voltaria ao mesmo lugar. E o que o original faz.

local terminal = mod.import("lib/terminal.lua")

return function(ctx)
    return terminal.abrir(ctx)
end
