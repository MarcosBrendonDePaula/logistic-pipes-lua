-- A viagem do item pelo cano: um passo por tique, guardado na posicao.
--
-- Era a maior diferenca visivel entre este porte e o original. Ate aqui a entrega era instantanea:
-- o item sumia de um bau e aparecia no outro, e a rede funcionava sem se parecer com uma rede. O
-- Logistic Pipes move o item de cano em cano, e e disso que vem a sensacao de que a base esta viva.
--
-- Como funciona. A carga fica no `block_data` do cano em que esta -- e nao numa tabela do mod. Sao
-- duas propriedades que so essa escolha da:
--
--   1. Ela sobrevive ao servidor cair, porque `block_data` e gravado com o chunk.
--   2. Ela some junto com o cano, em vez de ficar apontando para uma posicao que nao existe mais.
--
-- E o tique vem de `schedule_block`, que usa a fila do proprio jogo -- gravada com o chunk pela
-- mesma razao. Um temporizador do mod perderia toda carga em transito no primeiro desligamento.

local rede = mod.import("lib/rede.lua")

-- Tiques entre um cano e o proximo.
--
-- Quatro e o que faz a viagem ser visivel sem ser lenta: um cano de vinte blocos leva quatro
-- segundos. O original acelera com canos melhores, e e por aqui que isso entraria.
local TIQUES_POR_CANO = 4

-- Quantas cargas um cano segura ao mesmo tempo.
--
-- O teto existe porque cada carga custa uma leitura e uma escrita de `block_data` por tique. Sem
-- ele, mandar mil pedidos de uma vez transformaria um cano num laco que estoura o orcamento de 20
-- ms -- e o sintoma seria a rede inteira parando, nao o cano que encheu.
local MAX_CARGAS = 16

--- Le as cargas paradas naquele cano.
local function cargas_em(ctx, x, y, z)
    local dados = ctx.server.get_block_data(x, y, z)
    return dados.cargas or {}, dados
end

--- Poe uma carga num cano e agenda o tique que vai move-la.
--
-- Devolve false quando o cano ja esta cheio. Quem chama precisa tratar isso -- devolver o item para
-- onde veio -- em vez de ignorar: uma carga que nao coube e um item que deixou de existir, o pior
-- defeito possivel num mod de logistica.
local function por_carga(ctx, x, y, z, carga)
    local cargas, dados = cargas_em(ctx, x, y, z)
    if #cargas >= MAX_CARGAS then return false end

    cargas[#cargas + 1] = carga
    dados.cargas = cargas
    ctx.server.set_block_data(x, y, z, dados)

    -- Agendar sempre, e nao so quando era a primeira carga: cada carga anda no proprio tique, e
    -- economizar aqui faria a segunda carga esperar a primeira chegar.
    ctx.server.schedule_block(x, y, z, TIQUES_POR_CANO)
    return true
end

--- Tenta entregar a carga num inventario encostado neste cano.
--
-- Devolve quanto sobrou. Serve para o fim da rota e tambem para o desvio de emergencia, quando a
-- rota quebrou no meio -- e melhor o item aparecer num bau vizinho do que sumir.
local function descarregar(ctx, x, y, z, carga)
    local resta = carga.count

    for _, alvo in ipairs(rede.inventarios_em(ctx, { x = x, y = y, z = z })) do
        if resta <= 0 then break end
        resta = ctx.server.insert_into(alvo.x, alvo.y, alvo.z, carga.item, resta)
    end
    return resta
end

--- O tique de um cano: cada carga anda um passo.
--
-- Chamado pelo evento `block_scheduled`, uma vez por tique agendado. O cano nao se reagenda sozinho
-- quando esvazia -- e o que impede uma rede parada de continuar custando tique para sempre.
local function passo(ctx, x, y, z)
    local cargas, dados = cargas_em(ctx, x, y, z)
    if #cargas == 0 then return end

    local ficam = {}

    for _, carga in ipairs(cargas) do
        local proximo = carga.rota[carga.passo + 1]

        if proximo == nil then
            -- Chegou ao fim da rota: descarrega no bau do terminal.
            local sobrou = descarregar(ctx, x, y, z, carga)
            if sobrou > 0 then
                -- O bau encheu enquanto o item viajava. A carga espera aqui e tenta de novo, em vez
                -- de sumir; o cano vira uma fila, que e o que o jogador espera ver.
                carga.count = sobrou
                ficam[#ficam + 1] = carga
            end
        elseif not rede.e_cano(ctx, proximo.x, proximo.y, proximo.z) then
            -- Alguem quebrou o cano na frente enquanto o item viajava. Sem evento de bloco quebrado
            -- com a rede intacta, este e o momento em que se descobre -- e o desvio para um bau
            -- vizinho e o que impede o item de desaparecer.
            local sobrou = descarregar(ctx, x, y, z, carga)
            if sobrou > 0 then
                carga.count = sobrou
                ficam[#ficam + 1] = carga
            end
        else
            carga.passo = carga.passo + 1
            if not por_carga(ctx, proximo.x, proximo.y, proximo.z, carga) then
                -- O cano da frente encheu: a carga espera aqui. Voltar o passo importa, senao ela
                -- pularia um cano ao seguir viagem.
                carga.passo = carga.passo - 1
                ficam[#ficam + 1] = carga
            end
        end
    end

    dados.cargas = ficam
    ctx.server.set_block_data(x, y, z, dados)

    -- Reagenda so se sobrou alguem esperando. Um cano vazio nao volta a ser chamado.
    if #ficam > 0 then
        ctx.server.schedule_block(x, y, z, TIQUES_POR_CANO)
    end
end

--- Poe um item na rede para viajar ate o terminal.
--
-- Devolve quanto entrou de fato. O numero real: um cano de saida cheio e normal, e mentir sobre
-- isso faria quem pediu procurar itens que nunca sairam.
local function despachar(ctx, origem, rota, item, quantidade)
    local carga = { item = item, count = quantidade, rota = rota, passo = 1 }
    if por_carga(ctx, origem.x, origem.y, origem.z, carga) then
        return quantidade
    end
    return 0
end

--- Tira do provedor e manda pela rede ate o terminal.
--
-- Devolve quanto de fato saiu, e o motivo quando nao saiu tudo. O numero real, e nao o pedido: um
-- provedor que ficou sem estoque entre a leitura e a entrega e normal, e mentir sobre isso faria
-- quem pediu procurar itens que nunca sairam.
--
-- Antes esta funcao inseria direto no bau de destino. Agora ela poe o item no cano provedor e deixa
-- a rede levar -- o item existe em algum lugar do caminho durante a viagem, e nao em lugar nenhum.
local function entregar(ctx, nos, terminal, item, quantidade)
    local alvo = rede.destino(ctx, terminal)
    if alvo == nil then return 0, "sem bau encostado no terminal" end

    local despachado = 0
    local motivo = nil

    for _, no in ipairs(nos) do
        if despachado >= quantidade then break end

        if no.bloco == "logistica:provedor" then
            -- A rota e tracada uma vez por provedor, e nao por item: dentro de um callback com 20
            -- ms de orcamento, uma busca em largura por pilha entregue seria o que estoura.
            local caminho = rede.rota(ctx, no, terminal)

            if caminho == nil then
                motivo = "sem caminho de canos ate o terminal"
            else
                for _, fonte in ipairs(rede.inventarios_em(ctx, no)) do
                    if despachado >= quantidade then break end

                    -- O provedor que divide o bau com o destino e pulado. Sem isto o item sairia e
                    -- voltaria ao mesmo lugar indefinidamente.
                    if not rede.mesmo_lugar(fonte, alvo) then
                        local pegar = quantidade - despachado
                        local tirado = ctx.server.extract_from(fonte.x, fonte.y, fonte.z, item, pegar)

                        if tirado > 0 then
                            local entrou = despachar(ctx, no, caminho, item, tirado)
                            despachado = despachado + entrou

                            -- O que nao coube no cano volta para o bau de onde saiu. Sem isto, uma
                            -- rede congestionada apagaria item do mundo.
                            if entrou < tirado then
                                ctx.server.insert_into(fonte.x, fonte.y, fonte.z, item, tirado - entrou)
                                motivo = "a rede esta cheia"
                            end
                        end
                    end
                end
            end
        end
    end

    if despachado == 0 then
        return 0, motivo or "a rede nao tem esse item agora"
    end
    return despachado, motivo
end

return {
    TIQUES_POR_CANO = TIQUES_POR_CANO,
    entregar = entregar,
    MAX_CARGAS = MAX_CARGAS,
    cargas_em = cargas_em,
    passo = passo,
    despachar = despachar,
}
