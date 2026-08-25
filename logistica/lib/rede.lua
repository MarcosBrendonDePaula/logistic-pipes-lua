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
    ["logistica:provedor_mk2"] = true,
    ["logistica:terminal"] = true,
    ["logistica:abastecedor"] = true,
    ["logistica:satelite"] = true,
    ["logistica:fabricador"] = true,
    ["logistica:fabricador_mk2"] = true,
    ["logistica:fabricador_mk3"] = true,
    ["logistica:chassi"] = true,
}

-- Quanto cada provedor manda por pedido.
--
-- Os numeros sao do original: o Mk1 manda 16 e o Mk2 manda uma pilha. Manter os 16 no primeiro e o
-- que torna o Mk2 uma melhoria de verdade, e nao um cano mais bonito.
--
-- **A tabela existe para a pergunta "isto e um provedor?" morar num lugar so.** Ela estava escrita
-- como `no.bloco == "logistica:provedor"` em quatro arquivos, e acrescentar o Mk2 significaria
-- lembrar dos quatro -- o que ficasse para tras daria um provedor que aparece na rede e nunca
-- entrega, sem erro nenhum no log.
local PROVEDORES = {
    ["logistica:provedor"] = 16,
    ["logistica:provedor_mk2"] = 64,
}

-- Ate onde cada fabricador desce a arvore de pedido, e quantos nos ela pode ter.
--
-- E o que separa as tres versoes do original: o Mk1 resolve uma receita de um nivel, e o Mk3
-- monta a cadeia inteira. Os limites nao sao enfeite -- a arvore roda dentro de um callback com 20
-- ms, e sem teto uma receita circular nao terminaria.
local FABRICADORES = {
    ["logistica:fabricador"] = { profundidade = 5, nos = 64 },
    ["logistica:fabricador_mk2"] = { profundidade = 8, nos = 128 },
    ["logistica:fabricador_mk3"] = { profundidade = 12, nos = 256 },
}

--- Se aquele bloco oferece o estoque do bau encostado, e quanto manda por pedido.
local function e_provedor(bloco)
    return PROVEDORES[bloco] ~= nil
end

local function por_pedido_de(bloco)
    return PROVEDORES[bloco] or 0
end

--- Os limites de planejamento daquele fabricador, ou os do Mk1 quando nao for um.
local function limites_de(bloco)
    return FABRICADORES[bloco] or FABRICADORES["logistica:fabricador"]
end

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

--- Se aquela posicao ainda e um cano da rede.
--
-- Usado pela viagem a cada passo: o cano da frente pode ter sido quebrado desde que a rota foi
-- tracada, e descobrir isso na hora de andar e o que impede a carga de sumir num buraco.
local function e_cano(ctx, x, y, z)
    return CANOS[ctx.server.get_block(x, y, z)] == true
end

--- O caminho de canos entre duas posicoes, ou nil se nao houver.
--
-- A mesma busca em largura de `varrer`, guardando de onde se chegou a cada no -- e por isso o
-- caminho devolvido e o mais curto em numero de canos. O original cobra por custo de rota
-- (getIRoutersByCost); aqui o custo e o comprimento, que e a versao honesta enquanto nao houver
-- canos de velocidades diferentes.
local function rota(ctx, origem, destino)
    if origem.x == destino.x and origem.y == destino.y and origem.z == destino.z then
        return { { x = origem.x, y = origem.y, z = origem.z } }
    end

    local de_onde = {}
    local vistos = { [chave(origem.x, origem.y, origem.z)] = true }
    local fila = { { x = origem.x, y = origem.y, z = origem.z } }
    local frente = 1
    local visitados = 1

    while frente <= #fila do
        local atual = fila[frente]
        frente = frente + 1

        for _, lado in ipairs(LADOS) do
            local nx, ny, nz = atual.x + lado.x, atual.y + lado.y, atual.z + lado.z
            local k = chave(nx, ny, nz)

            if not vistos[k] and CANOS[ctx.server.get_block(nx, ny, nz)] then
                vistos[k] = true
                de_onde[k] = atual
                visitados = visitados + 1

                if nx == destino.x and ny == destino.y and nz == destino.z then
                    -- Refaz o caminho de tras para frente e inverte: guardar a rota inteira em cada
                    -- no durante a busca custaria memoria proporcional ao quadrado da rede.
                    local invertido = { { x = nx, y = ny, z = nz } }
                    local passo = atual
                    while passo do
                        invertido[#invertido + 1] = { x = passo.x, y = passo.y, z = passo.z }
                        passo = de_onde[chave(passo.x, passo.y, passo.z)]
                    end

                    local caminho = {}
                    for i = #invertido, 1, -1 do caminho[#caminho + 1] = invertido[i] end
                    return caminho
                end

                fila[#fila + 1] = { x = nx, y = ny, z = nz }

                -- O mesmo teto de `varrer`, pela mesma razao: a busca roda dentro de um callback
                -- com orcamento de 20 ms.
                if visitados >= MAX_NOS then return nil end
            end
        end
    end
    return nil
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
        if e_provedor(no.bloco) then
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

return {
    CANOS = CANOS,
    PROVEDORES = PROVEDORES,
    FABRICADORES = FABRICADORES,
    e_provedor = e_provedor,
    por_pedido_de = por_pedido_de,
    limites_de = limites_de,
    MAX_NOS = MAX_NOS,
    POR_PEDIDO = POR_PEDIDO,
    varrer = varrer,
    rota = rota,
    e_cano = e_cano,
    inventarios_em = inventarios_em,
    estoque = estoque,
    destino = destino,
    mesmo_lugar = mesmo_lugar,
}
