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

--- Define o papel de um slot, e quanto passa por ele.
--
-- **A quantidade e por slot, e nao uma por receita.** Uma prensa que come oito tabuas e devolve um
-- bau precisa dizer oito num lado e um no outro; enquanto o mapa so sabia dizer "um de cada", toda
-- receita que nao fosse 1 para 1 ficava fora do alcance -- e a maioria e.
--
-- Ausente vale um, que era o comportamento anterior: quem ja tinha mapa nao precisa reconfigurar.
local function definir(ctx, x, y, z, slot, papel, item, quantidade)
    if not PAPEIS[papel] then
        return false, "papel deve ser entrada, saida ou nenhum"
    end

    quantidade = tonumber(quantidade) or 1
    if quantidade < 1 then quantidade = 1 end
    if quantidade > 64 then quantidade = 64 end

    local mapa, dados = mapa_de(ctx, x, y, z)
    if papel == "nenhum" then
        mapa[tostring(slot)] = nil
    else
        mapa[tostring(slot)] = { papel = papel, item = item, count = quantidade }
    end

    dados.maquina = mapa
    ctx.server.set_block_data(x, y, z, dados)
    return true
end

--- Define varios slots de uma vez, com uma escrita so.
--
-- Cada `definir` le e grava o `block_data` do cano. Configurar uma maquina inteira slot a slot
-- paga isso uma vez por slot, e o orcamento de 20 ms por callback nao tem essa folga quando o
-- mesmo tique ainda monta a rede -- foi assim que dois casos da bateria estouraram sem nada de
-- errado na logica deles.
--
-- Recebe uma lista de { slot, papel, item, count }.
local function definir_varios(ctx, x, y, z, lista)
    local mapa, dados = mapa_de(ctx, x, y, z)

    for _, entrada in ipairs(lista) do
        if not PAPEIS[entrada.papel] then
            return false, "papel deve ser entrada, saida ou nenhum"
        end

        if entrada.papel == "nenhum" then
            mapa[tostring(entrada.slot)] = nil
        else
            local quantos = tonumber(entrada.count) or 1
            if quantos < 1 then quantos = 1 end
            if quantos > 64 then quantos = 64 end
            mapa[tostring(entrada.slot)] = {
                papel = entrada.papel, item = entrada.item, count = quantos,
            }
        end
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

    -- Onde cada slot aparece na tela da propria maquina, quando ela tem uma.
    --
    -- E o que permite a tela de configuracao ter **a forma da maquina** em vez de uma fileira: o
    -- jogador reconhece a fornalha pelos tres slots em L, e contar posicoes numa lista para saber
    -- qual e qual e trabalho que a forma dispensa.
    --
    -- Vazio quando o bloco nao tem menu proprio -- um bau de outro mod, por exemplo --, e ai quem
    -- desenha cai na fileira.
    local desenho = {}
    local ok, layout = pcall(function()
        return ctx.server.container_slot_layout(maquina.x, maquina.y, maquina.z)
    end)
    if ok and layout ~= nil then
        for _, posicao in ipairs(layout) do
            desenho[posicao.slot] = posicao
        end
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
            quantidade = config.count or 1,
            x = desenho[slot] and desenho[slot].x or nil,
            y = desenho[slot] and desenho[slot].y or nil,
        }
    end
    return slots
end

--- Por onde um ingrediente entra nesta maquina, **em ordem de slot**.
--
-- Devolve a lista de slots que aceitam aquele item, cada um com quanto cabe nele por lote. Quem
-- insere enche o primeiro ate a conta dele e so entao passa para o proximo.
--
-- **A ordem importa, e ela nao existia.** A versao anterior devolvia um slot so, escolhido com
-- `pairs` -- que em Lua nao tem ordem nenhuma. Com duas entradas do mesmo item, tudo caia sempre
-- na mesma e a outra ficava vazia; pior, qual das duas nem era estavel entre execucoes. Uma
-- maquina com dois slots de entrada e comum, e era impossivel abastecer os dois.
--
-- Vencem os slots que pedem **aquele item**; depois, as entradas sem filtro. E o que faz o carvao
-- ir para o combustivel e o minerio para o forno, sem o mod saber o que e uma fornalha.
--
-- Lista vazia quando nao ha mapa: ai quem decide e a propria maquina, como sempre foi.
local function entradas_para(ctx, cano, item)
    local mapa = mapa_de(ctx, cano.x, cano.y, cano.z)

    local comFiltro, semFiltro = {}, {}
    for chave, config in pairs(mapa) do
        if config.papel == "entrada" then
            local slot = tonumber(chave)
            if slot ~= nil then
                if config.item == item then
                    comFiltro[#comFiltro + 1] = { slot = slot, count = config.count or 1 }
                elseif config.item == nil then
                    semFiltro[#semFiltro + 1] = { slot = slot, count = config.count or 64 }
                end
            end
        end
    end

    -- Em ordem crescente de slot: e a ordem que o jogador ve na tela da maquina, e a unica que faz
    -- "o slot 0 primeiro" significar alguma coisa.
    local function por_slot(a, b) return a.slot < b.slot end
    table.sort(comFiltro, por_slot)
    table.sort(semFiltro, por_slot)

    for _, entrada in ipairs(semFiltro) do comFiltro[#comFiltro + 1] = entrada end
    return comFiltro
end

--- Quanto vai para cada slot de entrada, dada a quantidade que chegou.
--
-- **A conta do mapa e um minimo para a maquina funcionar, e nao um teto.** Uma prensa que exige
-- duas tabuas nao trabalha com uma; com quatro ela trabalha duas vezes. Tratar a conta como teto
-- deixava material parado do lado de fora enquanto a maquina tinha espaco.
--
-- Duas passadas, e a ordem entre elas e o que importa:
--
--  1. **Um a um, ate cada slot atingir o minimo.** Com dois slots pedindo um e um unico item, ele
--     vai para o primeiro -- comecar a encher o segundo antes de o primeiro fechar o minimo daria
--     dois slots incompletos e uma maquina que nao roda.
--  2. **O que sobrar enche os slots**, porque nesse ponto todo minimo ja esta garantido: o que
--     entra a mais so adianta o proximo ciclo.
local function distribuir(entradas, quantos, lotes)
    lotes = lotes or 1

    local plano = {}
    for i = 1, #entradas do plano[i] = 0 end
    if #entradas == 0 then return plano, quantos end

    local restam = quantos

    -- Primeira passada: um a um ate o minimo de cada.
    local avancou = true
    while restam > 0 and avancou do
        avancou = false
        for i, entrada in ipairs(entradas) do
            if restam <= 0 then break end
            local minimo = (entrada.count or 1) * lotes
            if plano[i] < minimo then
                plano[i] = plano[i] + 1
                restam = restam - 1
                avancou = true
            end
        end
    end

    -- Segunda passada: o excedente, ate a pilha cheia.
    avancou = true
    while restam > 0 and avancou do
        avancou = false
        for i in ipairs(entradas) do
            if restam <= 0 then break end
            if plano[i] < 64 then
                plano[i] = plano[i] + 1
                restam = restam - 1
                avancou = true
            end
        end
    end

    return plano, restam
end

--- O primeiro slot de entrada, para quem so precisa de um.
local function entrada_para(ctx, cano, item)
    local entradas = entradas_para(ctx, cano, item)
    return entradas[1] and entradas[1].slot or nil
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
--
-- O mapa numa variavel, e nao direto no `next`: `mapa_de` devolve **dois** valores, e uma chamada
-- de varios retornos como ultimo argumento se expande -- o segundo virava a chave, e `next`
-- respondia "invalid key". A armadilha e do Lua e nao aparece na leitura.
local function tem_mapa(ctx, x, y, z)
    local mapa = mapa_de(ctx, x, y, z)
    return next(mapa) ~= nil
end

return {
    PAPEIS = PAPEIS,
    mapa_de = mapa_de,
    definir = definir,
    definir_varios = definir_varios,
    listar = listar,
    entrada_para = entrada_para,
    entradas_para = entradas_para,
    distribuir = distribuir,
    entradas_para = entradas_para,
    saida_para = saida_para,
    tem_mapa = tem_mapa,
}
