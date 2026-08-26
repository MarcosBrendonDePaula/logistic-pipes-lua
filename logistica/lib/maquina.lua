-- Falar com uma maquina que o loader nao conhece.
--
-- **O problema.** Um fabricador acoplado a um bau funciona: joga o material dentro e tira o produto.
-- Acoplado a uma fornalha, nao: o carvao vai parar no slot do minerio, o minerio no do combustivel,
-- e o produto e puxado de volta como se fosse ingrediente. O loader nao sabe o que e cada slot, e a
-- maquina nao tem como dizer.
--
-- **A saida.** Ninguem precisa saber -- o jogador sabe. A maquina tem N slots; o mod lista os N e
-- deixa dizer, de cada um, se e **entrada**, **saida** ou nada. Opcionalmente com o item que passa
-- ali, que e o que separa o slot do minerio do slot do combustivel numa fornalha.
--
-- Isso funciona para qualquer maquina de qualquer mod, sem o loader nem este mod conhecerem nenhuma:
-- e a mesma ideia do resultado declarado, aplicada aos slots.

local PAPEIS = { entrada = true, saida = true, nenhum = true }

--- O mapa de slots guardado no cano.
--
-- No `block_data` do cano, e nao da maquina: a maquina e de outro mod e pode nem guardar dados. E o
-- mapa e uma decisao sobre **este acoplamento** -- a mesma fornalha acoplada a dois canos pode ser
-- entrada de um e saida do outro.
local function mapa_de(ctx, x, y, z)
    local dados = ctx.server.get_block_data(x, y, z)
    return dados.maquina or {}, dados
end

local function definir(ctx, x, y, z, slot, papel, item)
    if not PAPEIS[papel] then
        return false, "papel deve ser entrada, saida ou nenhum"
    end

    local mapa, dados = mapa_de(ctx, x, y, z)
    if papel == "nenhum" then
        mapa[tostring(slot)] = nil
    else
        mapa[tostring(slot)] = { papel = papel, item = item }
    end

    dados.maquina = mapa
    ctx.server.set_block_data(x, y, z, dados)
    return true
end

--- Os slots da maquina, com o que esta em cada um e o papel declarado.
--
-- Lista **todos**, inclusive os vazios: `container_at` devolve so o que tem item, e numa fornalha o
-- slot que interessa -- a saida -- costuma estar vazio justamente quando se quer configura-lo.
local function listar(ctx, cano, maquina)
    local mapa = mapa_de(ctx, cano.x, cano.y, cano.z)
    local total = ctx.server.container_size(maquina.x, maquina.y, maquina.z)

    local conteudo = {}
    for _, entrada in ipairs(ctx.server.container_at(maquina.x, maquina.y, maquina.z)) do
        conteudo[entrada.slot] = entrada
    end

    local slots = {}
    for slot = 0, total - 1 do
        local config = mapa[tostring(slot)] or {}
        slots[#slots + 1] = {
            slot = slot,
            item = conteudo[slot] and conteudo[slot].item or nil,
            count = conteudo[slot] and conteudo[slot].count or 0,
            papel = config.papel or "nenhum",
            filtro = config.item,
        }
    end
    return slots
end

--- Para onde um ingrediente deve ir, nesta maquina.
--
-- Vence o slot que pede **aquele item**; depois, qualquer entrada sem filtro. E o que faz o carvao
-- ir para o combustivel e o minerio para o forno, sem o mod saber o que e uma fornalha.
--
-- Devolve nil quando nao ha mapa: ai quem decide e a propria maquina, como sempre foi.
local function entrada_para(ctx, cano, item)
    local mapa = mapa_de(ctx, cano.x, cano.y, cano.z)

    local livre = nil
    for chave, config in pairs(mapa) do
        if config.papel == "entrada" then
            if config.item == item then return tonumber(chave) end
            if config.item == nil and livre == nil then livre = tonumber(chave) end
        end
    end
    return livre
end

--- De onde tirar o produto, nesta maquina.
local function saida_para(ctx, cano, item)
    local mapa = mapa_de(ctx, cano.x, cano.y, cano.z)

    local livre = nil
    for chave, config in pairs(mapa) do
        if config.papel == "saida" then
            if config.item == item then return tonumber(chave) end
            if config.item == nil and livre == nil then livre = tonumber(chave) end
        end
    end
    return livre
end

--- Se aquele cano tem algum slot mapeado.
local function tem_mapa(ctx, x, y, z)
    return next(mapa_de(ctx, x, y, z)) ~= nil
end

return {
    PAPEIS = PAPEIS,
    mapa_de = mapa_de,
    definir = definir,
    listar = listar,
    entrada_para = entrada_para,
    saida_para = saida_para,
    tem_mapa = tem_mapa,
}
