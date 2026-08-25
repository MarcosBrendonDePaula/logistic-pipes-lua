-- O chassi: um cano cujo comportamento vem dos modulos que estao dentro dele.
--
-- No original ele e o `chassis`, e e a peca que muda como se joga. Sem ele a rede so faz o que se
-- pede a mao; com ele, cada bau da base ganha um papel -- este recebe ferro, aquele exporta o que
-- produz, aquele outro se mantem abastecido -- e a rede passa a funcionar sozinha.
--
-- **O comportamento e um item dentro do bloco, e nao uma configuracao.** E assim que o original
-- faz, e a razao e boa: trocar o papel de um bau e trocar um item de lugar, sem comando nenhum, e o
-- que esta ali se ve pela tela do bloco. Um chassi vazio nao faz nada e nao custa nada.
--
-- Os tres modulos daqui sao os que sustentam o resto:
--
--   extrator      tira do bau encostado e manda para quem na rede aceitar
--   deposito      declara que este bau recebe um item; a rede entrega aqui
--   abastecedor   mantem o bau com uma quantidade, como o cano abastecedor
--
-- `quick_sort`, `terminus` e `crafter` do original sao variacoes destes.

local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")

-- De quanto em quanto um chassi age.
--
-- Vinte tiques, um segundo. Mais rapido que o abastecedor porque um extrator parado e material
-- parado, e mais lento que o tique do cano porque cada volta le o inventario dos modulos.
local INTERVALO = 20

-- Quanto um extrator manda por vez.
--
-- Uma pilha por volta. Mandar tudo de uma vez encheria a rede com cargas de um bau so, e o resto da
-- base ficaria esperando -- o mesmo motivo de o provedor do original mandar 16.
local POR_VEZ = 16

local MODULOS = {
    ["logistica:modulo_extrator"] = "extrator",
    ["logistica:modulo_deposito"] = "deposito",
    ["logistica:modulo_abastecedor"] = "abastecedor",
}

--- Os modulos que estao dentro daquele chassi, por slot.
--
-- Le o inventario do proprio bloco. O que nao e modulo e ignorado em silencio: o inventario e
-- aberto por quem joga, e recusar um item ali seria recusar um engano sem consequencia.
local function modulos_em(ctx, x, y, z)
    local encontrados = {}

    for _, entrada in ipairs(ctx.server.container_at(x, y, z)) do
        local tipo = MODULOS[entrada.item]
        if tipo ~= nil then
            encontrados[#encontrados + 1] = { tipo = tipo, slot = entrada.slot }
        end
    end
    return encontrados
end

--- A configuracao de um slot de modulo, guardada na posicao do chassi.
--
-- Por slot, e nao por chassi: dois depositos no mesmo bloco recebem itens diferentes, e e disso que
-- vem a utilidade de ter mais de um slot.
local function configuracao(ctx, x, y, z, slot)
    local dados = ctx.server.get_block_data(x, y, z)
    local todos = dados.modulos or {}
    return todos[tostring(slot)] or {}, dados
end

local function configurar(ctx, x, y, z, slot, config)
    local dados = ctx.server.get_block_data(x, y, z)
    dados.modulos = dados.modulos or {}
    dados.modulos[tostring(slot)] = config
    ctx.server.set_block_data(x, y, z, dados)
end

-- ------------------------------------------------------------------ o que a rede pergunta

--- Onde na rede um item e aceito.
--
-- Devolve a posicao do chassi que o recebe, ou nil. E a pergunta que o original chama de
-- `sinksItem`, e e o que faz um item extraido saber para onde ir sem ninguem dizer.
--
-- O primeiro que aceita ganha, e a varredura devolve os canos em ordem de distancia: o deposito
-- mais perto atende. Prioridade explicita, como a do original, seria o passo seguinte.
local function quem_aceita(ctx, nos, item)
    for _, no in ipairs(nos) do
        if no.bloco == "logistica:chassi" then
            for _, modulo in ipairs(modulos_em(ctx, no.x, no.y, no.z)) do
                if modulo.tipo == "deposito" then
                    local config = configuracao(ctx, no.x, no.y, no.z, modulo.slot)
                    if config.item == item then return no end
                end
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------ o tique

--- Um extrator: tira do bau encostado e manda para quem aceitar.
local function agir_extrator(ctx, nos, no, config)
    if config.item == nil then return 0 end

    local destino = quem_aceita(ctx, nos, config.item)
    if destino == nil then return 0 end

    -- Nao manda para si mesmo: o item sairia e voltaria ao mesmo bau para sempre, e a rede
    -- pareceria trabalhar sem nada acontecer.
    if destino.x == no.x and destino.y == no.y and destino.z == no.z then return 0 end

    local caminho = rede.rota(ctx, no, destino)
    if caminho == nil then return 0 end

    local enviado = 0
    for _, fonte in ipairs(rede.inventarios_em(ctx, no)) do
        if enviado >= POR_VEZ then break end

        local tirado = ctx.server.extract_from(fonte.x, fonte.y, fonte.z,
                                               config.item, POR_VEZ - enviado)
        if tirado > 0 then
            local carga = { item = config.item, count = tirado, rota = caminho, passo = 1 }
            if viagem.por_carga(ctx, no.x, no.y, no.z, carga) then
                enviado = enviado + tirado
            else
                -- A linha esta cheia: devolve, senao o item deixa de existir.
                ctx.server.insert_into(fonte.x, fonte.y, fonte.z, config.item, tirado)
            end
        end
    end
    return enviado
end

--- Um abastecedor de chassi: pede a rede o que falta para o bau chegar ao alvo.
local function agir_abastecedor(ctx, nos, no, config)
    if config.item == nil then return 0 end

    local alvo = tonumber(config.alvo) or 0
    if alvo <= 0 then return 0 end

    local tem = 0
    for _, destino in ipairs(rede.inventarios_em(ctx, no)) do
        for _, entrada in ipairs(ctx.server.container_at(destino.x, destino.y, destino.z)) do
            if entrada.item == config.item then tem = tem + entrada.count end
        end
    end

    local falta = alvo - tem
    if falta <= 0 then return 0 end

    return viagem.entregar(ctx, nos, no, config.item, falta)
end

--- O tique de um chassi: cada modulo age uma vez.
--
-- Reagenda sempre, porque um chassi existe para continuar agindo -- como o abastecedor, e ao
-- contrario do cano comum, que para quando esvazia.
local function passo(ctx, x, y, z)
    local no = { x = x, y = y, z = z, bloco = "logistica:chassi" }
    local modulos = modulos_em(ctx, x, y, z)

    if #modulos > 0 then
        -- A rede e varrida uma vez por tique, e nao uma vez por modulo: tres modulos no mesmo
        -- chassi fariam tres varreduras identicas, e o orcamento de 20 ms nao tem essa folga.
        local nos = rede.varrer(ctx, x, y, z)

        for _, modulo in ipairs(modulos) do
            local config = configuracao(ctx, x, y, z, modulo.slot)

            if modulo.tipo == "extrator" then
                agir_extrator(ctx, nos, no, config)
            elseif modulo.tipo == "abastecedor" then
                agir_abastecedor(ctx, nos, no, config)
            end
            -- O deposito nao age: ele responde quando a rede pergunta quem aceita.
        end
    end

    ctx.server.schedule_block(x, y, z, INTERVALO)
end

return {
    INTERVALO = INTERVALO,
    POR_VEZ = POR_VEZ,
    MODULOS = MODULOS,
    modulos_em = modulos_em,
    configuracao = configuracao,
    configurar = configurar,
    quem_aceita = quem_aceita,
    passo = passo,
}
