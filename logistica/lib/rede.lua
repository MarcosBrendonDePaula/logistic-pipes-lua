-- O nucleo da rede: descobrir, listar e entregar.
--
-- Fica num modulo porque duas partes precisam dele -- o main.lua, que desenha a tela, e o script de
-- comportamento do bloco, que abre o terminal. Duplicar seria o caminho curto e daria duas redes
-- que discordam no primeiro ajuste.
--
-- A logica segue a do Logistic Pipes original (RequestTreeNode.checkProvider), inclusive em duas
-- coisas que nao sao obvias e estao comentadas onde importam: a ordem por distancia e a recusa de
-- provedor que divide o bau com quem pediu.

local CANOS = {
    ["logistica:cano"] = true,
    ["logistica:provedor"] = true,
    ["logistica:terminal"] = true,
}

-- O quanto a rede pode crescer antes de o loader desistir de varre-la.
--
-- Nao e enfeite: a varredura roda dentro de um callback, e todo callback tem orcamento de 20 ms.
-- Uma rede sem teto acabaria estourando o orcamento no meio, e o sintoma seria o terminal parar de
-- abrir sem dizer por que.
local MAX_NOS = 256

-- Quanto o provedor manda por pedido. O numero e do mod original: o provedor Mk1 manda 16, e o Mk2
-- manda uma pilha. Manter os 16 e o que torna o Mk2 uma melhoria de verdade quando ele existir.
local POR_PEDIDO = 16

local LADOS = {
    { x =  1, y =  0, z =  0 },
    { x = -1, y =  0, z =  0 },
    { x =  0, y =  1, z =  0 },
    { x =  0, y = -1, z =  0 },
    { x =  0, y =  0, z =  1 },
    { x =  0, y =  0, z = -1 },
}

local function chave(x, y, z)
    return x .. "," .. y .. "," .. z
end

--- Varre a rede a partir de um cano, seguindo so por cano.
--
-- Uma busca em largura, e nao recursao: a rede de um jogador pode ter centenas de nos, e a pilha do
-- Lua sob orcamento nao e lugar para descobrir isso.
-- A varredura em largura devolve os canos em ordem de distancia, e isso nao e acidente: o original
-- pede os provedores por custo (getIRoutersByCost) para o mais perto atender primeiro. Aqui a
-- ordem da fila ja e essa, e a entrega percorre a lista na mesma ordem.
local function varrer(ctx, x, y, z)
    local vistos = { [chave(x, y, z)] = true }
    local fila = { { x = x, y = y, z = z } }
    local nos = { { x = x, y = y, z = z, bloco = ctx.server.get_block(x, y, z) } }
    local frente = 1

    while frente <= #fila do
        local atual = fila[frente]
        frente = frente + 1

        for _, lado in ipairs(LADOS) do
            local nx, ny, nz = atual.x + lado.x, atual.y + lado.y, atual.z + lado.z
            local k = chave(nx, ny, nz)

            if not vistos[k] then
                local bloco = ctx.server.get_block(nx, ny, nz)
                if CANOS[bloco] then
                    vistos[k] = true
                    fila[#fila + 1] = { x = nx, y = ny, z = nz }
                    nos[#nos + 1] = { x = nx, y = ny, z = nz, bloco = bloco }

                    -- O teto para a varredura, e nao a rede: o que passar daqui simplesmente nao e
                    -- enxergado, e o terminal continua funcionando com o que achou.
                    if #nos >= MAX_NOS then return nos, true end
                end
            end
        end
    end
    return nos, false
end

--- Os inventarios encostados num cano, que nao sejam cano.
--
-- E o que liga a rede ao mundo: um bau, um forno, ou o inventario de um bloco de outro mod. O
-- loader responde por capabilities_at, entao a rede alcanca qualquer coisa que guarde item -- e nao
-- so o que este mod declarou.
local function inventarios_em(ctx, no)
    local achados = {}

    for _, lado in ipairs(LADOS) do
        local x, y, z = no.x + lado.x, no.y + lado.y, no.z + lado.z

        if not CANOS[ctx.server.get_block(x, y, z)] then
            for _, capacidade in ipairs(ctx.server.capabilities_at(x, y, z)) do
                if capacidade == "items" then
                    achados[#achados + 1] = { x = x, y = y, z = z }
                    break
                end
            end
        end
    end
    return achados
end

--- Tudo que a rede oferece, somado por item.
--
-- So os provedores contam. Um bau encostado num cano comum nao entra: no original, e o cano provedor
-- que "attaches to an inventory" -- o resto da rede so transporta. Sem essa distincao, todo bau da
-- base viraria estoque publico sem ninguem ter pedido.
local function estoque(ctx, nos)
    local total = {}
    local ordem = {}

    for _, no in ipairs(nos) do
        if no.bloco == "logistica:provedor" then
            for _, alvo in ipairs(inventarios_em(ctx, no)) do
                for _, entrada in ipairs(ctx.server.container_at(alvo.x, alvo.y, alvo.z)) do
                    if total[entrada.item] == nil then
                        total[entrada.item] = 0
                        ordem[#ordem + 1] = entrada.item
                    end
                    total[entrada.item] = total[entrada.item] + entrada.count
                end
            end
        end
    end

    table.sort(ordem)
    local lista = {}
    for _, item in ipairs(ordem) do
        lista[#lista + 1] = { item = item, count = total[item] }
    end
    return lista
end

--- Onde a rede entrega: um inventario encostado no proprio terminal.
--
-- E como o original faz -- "put a chest on the pipe to catch items coming out". Entregar direto no
-- inventario de quem pediu seria mais comodo e menos honesto: a rede move itens entre baus, e quem
-- quiser recebe-los na mao ja tem o bau ali.
local function destino(ctx, terminal)
    local alvos = inventarios_em(ctx, terminal)
    return alvos[1]
end

--- Se dois cantos do mundo sao o mesmo bau.
--
-- O original recusa provedor que divide o container com quem pediu -- e o que a dica do mod chama
-- de "ignores Suppliers on the same block". Sem isso, um bau que e origem e destino ao mesmo tempo
-- faria o item sair e voltar para sempre, e a rede pareceria estar trabalhando sem nada acontecer.
local function mesmo_lugar(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end

--- Tira do provedor e poe no destino, ate a quantidade pedida.
--
-- Devolve quanto de fato foi entregue. O numero real, e nao o pedido: um bau cheio no destino ou um
-- provedor que ficou sem estoque entre a leitura e a entrega sao normais, e mentir sobre isso faria
-- quem pediu procurar itens que nunca sairam.
local function entregar(ctx, nos, terminal, item, quantidade)
    local alvo = destino(ctx, terminal)
    if alvo == nil then return 0, "sem bau encostado no terminal" end

    local entregue = 0

    for _, no in ipairs(nos) do
        if entregue >= quantidade then break end

        if no.bloco == "logistica:provedor" then
            for _, fonte in ipairs(inventarios_em(ctx, no)) do
                if entregue >= quantidade then break end

                -- O provedor que divide o bau com o destino e pulado. Sem isto o item sairia e
                -- voltaria ao mesmo lugar indefinidamente.
                if mesmo_lugar(fonte, alvo) then goto proxima_fonte end

                local pegar = quantidade - entregue
                local tirado = ctx.server.extract_from(fonte.x, fonte.y, fonte.z, item, pegar)

                if tirado > 0 then
                    local sobrou = ctx.server.insert_into(alvo.x, alvo.y, alvo.z, item, tirado)
                    entregue = entregue + (tirado - sobrou)

                    -- O que nao coube volta para onde veio. Sem isto, um bau de destino cheio
                    -- apagaria item do mundo -- o pior defeito possivel num mod de logistica.
                    if sobrou > 0 then
                        ctx.server.insert_into(fonte.x, fonte.y, fonte.z, item, sobrou)
                        return entregue, "o bau de destino encheu"
                    end
                end

                ::proxima_fonte::
            end
        end
    end

    if entregue == 0 then return 0, "a rede nao tem esse item agora" end
    return entregue, nil
end


return {
    CANOS = CANOS,
    MAX_NOS = MAX_NOS,
    POR_PEDIDO = POR_PEDIDO,
    varrer = varrer,
    inventarios_em = inventarios_em,
    estoque = estoque,
    entregar = entregar,
}
