-- O cano abastecedor e o cano satelite.
--
-- No original:
--
--   Supplier   "keeps an inventory stocked with items"
--   Satellite  um endereco nomeado na rede, para onde outros canos mandam
--
-- Os dois compartilham a mesma ideia: um cano com configuracao propria, guardada na posicao dele.
-- E por isso que moram no mesmo modulo -- separa-los daria dois arquivos com o mesmo comeco.

local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")

-- De quanto em quanto o abastecedor confere o bau.
--
-- Cem tiques, cinco segundos. O original confere com folga parecida, e a razao e a mesma: conferir
-- todo tique multiplicaria por vinte o custo de uma rede grande sem mudar nada do que se ve, porque
-- a viagem em si ja leva mais que isso.
local INTERVALO = 100

-- Quantas conferidas sem novidade antes de dar uma remessa por perdida.
--
-- Dez, ou quase um minuto. Uma carga pode demorar se a rede for longa ou estiver congestionada, e
-- desistir cedo faria o abastecedor pedir em dobro -- exatamente o que a pendencia existe para
-- evitar.
local PACIENCIA = 10

-- ------------------------------------------------------------------ configuracao por posicao

--- Le a configuracao daquele cano.
--
-- Fica no `block_data` do proprio cano: quebrar o cano leva a configuracao junto, que e o que quem
-- joga espera. Guardar num estado do mod deixaria configuracao orfa apontando para posicoes vazias.
local function configuracao(ctx, x, y, z)
    local dados = ctx.server.get_block_data(x, y, z)
    return dados.config or {}, dados
end

local function gravar(ctx, x, y, z, config)
    local _, dados = configuracao(ctx, x, y, z)
    dados.config = config
    ctx.server.set_block_data(x, y, z, dados)
end

-- ------------------------------------------------------------------ satelite

--- Da nome a um satelite, ou le o nome que ele tem.
--
-- O nome e o endereco: outro cano diz "mande para o satelite tal" sem saber onde ele fica. E o que
-- torna a rede reconfiguravel sem reeditar cada cano quando algo muda de lugar.
local function nome_do_satelite(ctx, x, y, z)
    local config = configuracao(ctx, x, y, z)
    return config.nome
end

local function nomear_satelite(ctx, x, y, z, nome)
    local config = configuracao(ctx, x, y, z)
    config.nome = nome
    gravar(ctx, x, y, z, config)
end

--- Acha o satelite daquele nome na rede a partir de um cano.
--
-- Devolve a posicao, ou nil. Nomes repetidos: vence o mais perto, porque a varredura devolve os
-- canos em ordem de distancia. Recusar o repetido seria mais rigoroso e menos util -- duas bases
-- com um satelite "forja" cada uma e um caso legitimo.
local function achar_satelite(ctx, nos, nome)
    for _, no in ipairs(nos) do
        if no.bloco == "logistica:satelite" then
            if nome_do_satelite(ctx, no.x, no.y, no.z) == nome then
                return no
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------ abastecedor

--- Configura o que aquele abastecedor mantem em estoque.
local function configurar_abastecedor(ctx, x, y, z, item, alvo)
    local config = configuracao(ctx, x, y, z)
    config.item = item
    config.alvo = alvo
    gravar(ctx, x, y, z, config)

    -- Comeca a conferir agora que ha o que conferir. Um abastecedor sem configuracao nao agenda
    -- nada, e por isso um cano recem-colocado nao custa tique nenhum.
    ctx.server.schedule_block(x, y, z, INTERVALO)
end

--- Quanto falta para o bau encostado chegar ao alvo.
--
-- Conta o que ja esta a caminho, senao o abastecedor pediria de novo a cada conferida enquanto a
-- primeira remessa ainda viaja, e o bau acabaria com varias vezes o alvo.
--
-- **O que esta a caminho e um numero guardado aqui, e nao uma varredura.** A primeira versao
-- percorria a rede inteira lendo os dados de cada cano para somar as cargas com este destino, e
-- isso estourou o orcamento de 20 ms na propria bateria de testes. Um abastecedor que custa uma
-- varredura completa a cada cinco segundos nao escala para uma base de verdade -- e o original
-- rastreia os pedidos justamente por isso.
local function quanto_falta(ctx, no, config)
    local alvo = tonumber(config.alvo) or 0
    if config.item == nil or alvo <= 0 then return 0 end

    local tem = 0
    for _, destino in ipairs(rede.inventarios_em(ctx, no)) do
        for _, entrada in ipairs(ctx.server.container_at(destino.x, destino.y, destino.z)) do
            if entrada.item == config.item then tem = tem + entrada.count end
        end
    end

    local falta = alvo - tem - (tonumber(config.pendente) or 0)
    return falta > 0 and falta or 0
end

--- Registra que uma remessa chegou a este abastecedor.
--
-- Chamada pela viagem quando a carga e descarregada. Sem isto a pendencia so cresceria, e o
-- abastecedor pararia de pedir para sempre depois da primeira remessa.
local function chegou(ctx, x, y, z, item, quantidade)
    local config, dados = configuracao(ctx, x, y, z)
    if config.item ~= item then return end

    local pendente = (tonumber(config.pendente) or 0) - quantidade
    config.pendente = pendente > 0 and pendente or 0
    config.paradas = 0

    dados.config = config
    ctx.server.set_block_data(x, y, z, dados)
end

--- O tique do abastecedor: confere o bau e pede o que falta.
--
-- Devolve quanto pediu, para quem chama poder registrar. Zero e o caso normal -- um abastecedor em
-- dia nao faz nada, e continua conferindo.
local function conferir(ctx, x, y, z)
    local config, dados = configuracao(ctx, x, y, z)
    if config.item == nil then return 0 end

    local no = { x = x, y = y, z = z, bloco = ctx.server.get_block(x, y, z) }
    local falta = quanto_falta(ctx, no, config)

    local pedido = 0
    if falta > 0 then
        local nos = rede.varrer(ctx, x, y, z)
        -- O abastecedor e o destino: a entrega vem dos provedores da rede para o bau dele.
        pedido = viagem.entregar(ctx, nos, no, config.item, falta)
        config.pendente = (tonumber(config.pendente) or 0) + pedido
        config.paradas = 0
    elseif (tonumber(config.pendente) or 0) > 0 then
        -- A pendencia esta segurando o pedido. Se ela nao andar por muitas conferidas, a remessa se
        -- perdeu -- alguem quebrou o cano com a carga dentro, e os dados dela foram junto. Sem esta
        -- saida o abastecedor ficaria mudo para sempre esperando algo que nao vem mais.
        config.paradas = (tonumber(config.paradas) or 0) + 1
        if config.paradas >= PACIENCIA then
            config.pendente = 0
            config.paradas = 0
            ctx.log.warn("Abastecedor em " .. x .. "," .. y .. "," .. z
                         .. " desistiu de uma remessa que nao chegou")
        end
    end

    dados.config = config
    ctx.server.set_block_data(x, y, z, dados)

    -- Reagenda sempre, porque um abastecedor existe justamente para continuar conferindo. E a
    -- excecao a regra do cano comum, que para de pedir tique quando esvazia.
    ctx.server.schedule_block(x, y, z, INTERVALO)
    return pedido
end

return {
    INTERVALO = INTERVALO,
    configuracao = configuracao,
    nome_do_satelite = nome_do_satelite,
    nomear_satelite = nomear_satelite,
    achar_satelite = achar_satelite,
    configurar_abastecedor = configurar_abastecedor,
    quanto_falta = quanto_falta,
    chegou = chegou,
    conferir = conferir,
}
