-- Esperar a maquina terminar.
--
-- **O problema.** Fabricar acontecia todo num tique: a rede punha o material na maquina e pedia o
-- produto no mesmo instante. Para um bau isso funciona -- o que entra sai --, mas uma fornalha
-- ainda nem acendeu. A resposta era "a maquina recebeu o material e ainda nao devolveu", o material
-- ficava la dentro, e quem pediu ficava clicando de novo empilhando material que nunca virava nada.
--
-- **A saida.** O cano anota o que esta esperando e agenda um tique. A cada tique ele confere o slot
-- de saida; quando o produto aparece, entrega no destino e esquece o pedido. Nada bloqueia: o
-- orcamento de 20 ms por callback proibe esperar dentro da chamada, e a fila do proprio jogo e
-- gravada com o chunk -- entao uma espera sobrevive ao servidor cair, como a carga em viagem ja
-- sobrevivia.
--
-- **O prazo existe.** Sem ele, uma fornalha sem combustivel deixaria o cano tiquando para sempre
-- por um produto que nao vem. Passado o prazo o cano desiste e avisa; o material fica na maquina,
-- que e onde ele estaria se alguem tivesse posto na mao.

local rede = mod.import("lib/rede.lua")

--- De quantos em quantos tiques o cano confere a maquina.
--
-- Vinte tiques e um segundo. Conferir a cada tique custaria vinte leituras de inventario por
-- segundo por cano esperando, para ganhar no maximo um segundo numa fornalha que leva dez.
local INTERVALO = 20

--- Quantas conferidas antes de desistir.
--
-- Sessenta conferidas a um segundo cada da um minuto -- mais que o dobro do que uma fornalha leva
-- para queimar uma pilha inteira, e curto o bastante para um engano nao virar um cano tiquando a
-- noite toda.
local TENTATIVAS = 60

--- Quantas ordens um cano guarda ao mesmo tempo.
--
-- **Uma fila, e nao uma espera so.** Com uma espera unica, pedir cinco carvoes ocupava o cano no
-- primeiro e os outros quatro eram recusados -- enquanto o material deles ja estava dentro da
-- fornalha, que continuava produzindo para ninguem recolher. E a mesma escolha do original: o
-- `LogisticsOrderManager` guarda uma lista de ordens no cano, e a que nao pode ser atendida agora
-- vai para o fim em vez de sumir.
--
-- Dezesseis e o teto porque a fila mora no `block_data`, que e gravado com o chunk: sem teto, um
-- botao segurado escreveria uma fila sem fim no disco.
local MAX_FILA = 16

--- A fila de ordens de um cano, e os dados em volta dela.
--
-- Aceita o formato antigo -- uma ordem so, em `esperando` -- e o converte em fila de um. Um mundo
-- salvo antes desta mudanca nao perde o que estava esperando.
local function fila_de(ctx, x, y, z)
    local dados = ctx.server.get_block_data(x, y, z)
    local fila = dados.esperando

    if fila == nil then return {}, dados end
    if fila.item ~= nil then return { fila }, dados end
    return fila, dados
end

local function gravar(ctx, x, y, z, dados, fila)
    dados.esperando = (#fila > 0) and fila or nil
    ctx.server.set_block_data(x, y, z, dados)
end

--- Anota mais uma ordem neste cano, e agenda a conferida.
--
-- O destino vai junto porque quem pediu pode ter fechado a tela: a entrega e do cano para o bau, e
-- nao da tela para quem clicou.
local function marcar(ctx, cano, maquina, item, quantos, destino)
    local fila, dados = fila_de(ctx, cano.x, cano.y, cano.z)
    if #fila >= MAX_FILA then return false end

    fila[#fila + 1] = {
        item = item,
        quantos = quantos,
        maquina = { x = maquina.x, y = maquina.y, z = maquina.z },
        destino = { x = destino.x, y = destino.y, z = destino.z },
        tentativas = 0,
    }
    gravar(ctx, cano.x, cano.y, cano.z, dados, fila)
    ctx.server.schedule_block(cano.x, cano.y, cano.z, INTERVALO)
    return true
end

--- Se a fila deste cano esta cheia.
--
-- E o unico motivo para recusar um pedido novo. Enquanto cabe ordem, o cano aceita: a maquina
-- trabalhar em fila e o comportamento esperado, e nao um erro.
local function cheio(ctx, x, y, z)
    local fila = fila_de(ctx, x, y, z)
    return #fila >= MAX_FILA
end

--- Quantas ordens este cano tem pendentes.
local function pendentes(ctx, x, y, z)
    local fila = fila_de(ctx, x, y, z)
    return #fila
end

--- Confere a maquina. Chamado pelo tique do cano.
--
-- **Uma ordem por tique**, e nao a fila inteira: percorrer dezesseis ordens significa dezesseis
-- leituras de inventario no mesmo callback, e o orcamento de 20 ms nao tem essa folga. A fila anda
-- um passo por segundo, que e mais rapido que qualquer maquina do jogo produz.
local function conferir(ctx, x, y, z)
    local fila, dados = fila_de(ctx, x, y, z)
    if #fila == 0 then return end

    local maquina = mod.import("lib/maquina.lua")
    local cano = { x = x, y = y, z = z }
    local ordem = fila[1]
    local alvo = ordem.maquina

    -- Slot fora do tamanho da maquina e ignorado: o mapa mora no cano e sobrevive a troca da
    -- maquina, entao um slot de um bau de 27 pode estar apontando para uma fornalha de 3.
    local slot = maquina.saida_para(ctx, cano, ordem.item)
    local tamanho = ctx.server.container_size(alvo.x, alvo.y, alvo.z)
    if slot ~= nil and (slot < 0 or slot >= tamanho) then slot = nil end

    local saiu = ctx.server.extract_from(alvo.x, alvo.y, alvo.z, ordem.item, ordem.quantos, slot)

    if saiu > 0 then
        local sobrou = ctx.server.insert_into(ordem.destino.x, ordem.destino.y, ordem.destino.z,
                                              ordem.item, saiu)
        ctx.log.info("LOGISTICA a maquina em " .. alvo.x .. "," .. alvo.y .. "," .. alvo.z
                     .. " devolveu " .. saiu .. " x " .. ordem.item
                     .. "; entregue em " .. ordem.destino.x .. ","
                     .. ordem.destino.y .. "," .. ordem.destino.z
                     .. (sobrou > 0 and (" (" .. sobrou .. " nao coube)") or "")
                     .. (#fila > 1 and ("; faltam " .. (#fila - 1) .. " na fila") or ""))

        -- Uma ordem parcialmente atendida continua na fila pelo resto: a maquina devolveu tres de
        -- oito porque ainda esta fazendo os outros cinco.
        ordem.quantos = ordem.quantos - saiu
        if ordem.quantos <= 0 then
            table.remove(fila, 1)
        else
            ordem.tentativas = 0
        end
    else
        ordem.tentativas = ordem.tentativas + 1
        if ordem.tentativas >= TENTATIVAS then
            -- **O material fica na maquina.** Devolve-lo para a rede seria pior: metade ja pode ter
            -- virado outra coisa, e um mod que tira item de dentro de maquina alheia acerta uma vez
            -- e erra em todas as maquinas que guardam estado.
            table.remove(fila, 1)
            ctx.log.warn("LOGISTICA desisti de esperar " .. ordem.item .. " da maquina em "
                         .. alvo.x .. "," .. alvo.y .. "," .. alvo.z
                         .. " -- o material continua la dentro; confira combustivel e energia")
        else
            -- A ordem que nao pode ser atendida agora vai para o fim, como no original: uma
            -- fornalha lenta no topo nao pode segurar um cascalho que ja esta pronto atras dela.
            if #fila > 1 then
                table.remove(fila, 1)
                fila[#fila + 1] = ordem
            end
        end
    end

    gravar(ctx, x, y, z, dados, fila)
    if #fila > 0 then ctx.server.schedule_block(x, y, z, INTERVALO) end
end

--- O que este cano esta esperando, para quem quiser mostrar na tela.
local function descrever(ctx, x, y, z)
    local fila = fila_de(ctx, x, y, z)
    if #fila == 0 then return nil end

    local texto = fila[1].quantos .. "x" .. fila[1].item
    if #fila > 1 then texto = texto .. " (+" .. (#fila - 1) .. " na fila)" end
    return texto
end

return {
    INTERVALO = INTERVALO,
    TENTATIVAS = TENTATIVAS,
    MAX_FILA = MAX_FILA,
    marcar = marcar,
    cheio = cheio,
    pendentes = pendentes,
    conferir = conferir,
    descrever = descrever,
}
