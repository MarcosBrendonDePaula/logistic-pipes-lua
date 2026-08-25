-- Clicar num provedor mostra o que ele oferece a rede.
--
-- No original o provedor tambem tem tela, para filtrar o que sai. Aqui ela ainda e so de leitura --
-- e o suficiente para responder a pergunta que se faz olhando um provedor: "este bau esta mesmo
-- entrando na rede?".
--
-- Quem PEDE e o terminal. A divisao e do original, e ela existe por um motivo: um provedor por bau
-- e comum, e ter tela de pedido em cada um faria a mesma lista aparecer em dez lugares.

local rede = mod.import("lib/rede.lua")

return function(ctx)
    local no = { x = ctx.block.x, y = ctx.block.y, z = ctx.block.z, bloco = "logistica:provedor" }
    local baus = rede.inventarios_em(ctx, no)

    if #baus == 0 then
        ctx.player.send_message("Provedor sem bau encostado: ele nao oferece nada a rede.")
        return false
    end

    local total = 0
    local linhas = 0
    for _, bau in ipairs(baus) do
        for _, entrada in ipairs(ctx.server.container_at(bau.x, bau.y, bau.z)) do
            total = total + entrada.count
            linhas = linhas + 1
            if linhas <= 5 then
                ctx.player.send_message("  " .. entrada.item .. " x" .. entrada.count)
            end
        end
    end

    if linhas == 0 then
        ctx.player.send_message("Provedor com bau vazio: nada a oferecer.")
    else
        ctx.player.send_message("Provedor oferece " .. linhas .. " tipo(s), " .. total .. " item(ns)."
                                .. (linhas > 5 and " (mostrando 5)" or ""))
        ctx.player.send_message("Para pedir, clique num Terminal Logistico da mesma rede.")
    end
    return false
end
