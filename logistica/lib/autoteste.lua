-- A bateria de verificacao do mod.
--
-- Ela existe porque este mod mora fora do repositorio do loader, e por isso nao alcanca os testes
-- de la. Sem uma verificacao propria, cada mudanca aqui dependeria de alguem lembrar de montar uma
-- rede a mao no jogo -- e a parte que mais quebra em silencio e justamente a que so aparece depois
-- de alguns tiques.
--
-- Ela monta redes de verdade num canto do mundo, exercita o ciclo e desmonta. E o mesmo desenho do
-- autoteste do loader: um comando roda tudo e escreve OK ou FALHOU por caso, com o motivo, entao
-- quem le o log sabe o que quebrou sem estar no jogo.
--
--   /mod logistica autoteste          roda tudo
--   /mod logistica autoteste <nome>   roda so um caso

local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")
local abastecimento = mod.import("lib/abastecimento.lua")

-- Onde a bateria monta as redes.
--
-- Perto do spawn, e nao num canto distante: a primeira versao usava x=512, e cada leitura de bloco
-- carregava um chunk que ninguem tinha aberto -- caro o bastante para estourar o orcamento de 20 ms
-- e parecer defeito do mod. O custo estava no mundo, nao no codigo.
--
-- As linhas ficam de duas em duas em x, o que deixa um bloco de ar entre elas. Encostadas, elas
-- virariam uma rede so e os casos passariam a interferir uns nos outros.
local BASE_X, BASE_Y, BASE_Z = 0, 100, 0

local function exigir(condicao, motivo)
    if not condicao then error(motivo, 2) end
end

--- Monta uma linha: bau, provedor, N canos, o bloco do fim, bau.
--
-- Devolve as posicoes que interessam. Limpa antes de construir: um teste que supoe o mundo limpo
-- falha na segunda execucao, e a mensagem acusa o proprio teste em vez do defeito.
local function montar(ctx, deslocamento, canos, bloco_final)
    local x = BASE_X + deslocamento
    local y, z = BASE_Y, BASE_Z

    for i = 0, canos + 3 do
        ctx.server.set_block("minecraft:air", x, y, z + i)
    end

    ctx.server.set_block("minecraft:chest", x, y, z)
    ctx.server.set_block("logistica:provedor", x, y, z + 1)
    for i = 2, canos + 1 do
        ctx.server.set_block("logistica:cano", x, y, z + i)
    end
    ctx.server.set_block(bloco_final, x, y, z + canos + 2)
    ctx.server.set_block("minecraft:chest", x, y, z + canos + 3)

    return {
        origem = { x = x, y = y, z = z },
        provedor = { x = x, y = y, z = z + 1, bloco = "logistica:provedor" },
        fim = { x = x, y = y, z = z + canos + 2, bloco = bloco_final },
        destino = { x = x, y = y, z = z + canos + 3 },
    }
end

local function desmontar(ctx, deslocamento, canos)
    local x, y, z = BASE_X + deslocamento, BASE_Y, BASE_Z
    for i = 0, canos + 3 do
        ctx.server.set_block("minecraft:air", x, y, z + i)
    end
end

local function quanto(ctx, pos, item)
    local total = 0
    for _, entrada in ipairs(ctx.server.container_at(pos.x, pos.y, pos.z)) do
        if entrada.item == item then total = total + entrada.count end
    end
    return total
end

local TESTES = {}

TESTES.rota = function(ctx)
    local r = montar(ctx, 0, 3, "logistica:terminal")

    local caminho = rede.rota(ctx, r.provedor, r.fim)
    exigir(caminho ~= nil, "deveria haver caminho entre provedor e terminal")
    -- Provedor, tres canos e o terminal: cinco.
    exigir(#caminho == 5, "o caminho deveria ter 5 canos, tem " .. #caminho)
    exigir(caminho[1].z == r.provedor.z, "o caminho deveria comecar no provedor")
    exigir(caminho[#caminho].z == r.fim.z, "e terminar no terminal")

    -- Cortado no meio, nao ha caminho -- e isso precisa ser nil, e nao um caminho torto.
    ctx.server.set_block("minecraft:air", r.provedor.x, r.provedor.y, r.provedor.z + 2)
    exigir(rede.rota(ctx, r.provedor, r.fim) == nil, "rede cortada nao deveria ter caminho")

    desmontar(ctx, 0, 3)
end

TESTES.entrega_viaja = function(ctx)
    local r = montar(ctx, 2, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:diamond", 12)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local entregue = viagem.entregar(ctx, nos, r.fim, "minecraft:diamond", 12)
    exigir(entregue == 12, "deveria ter despachado 12, despachou " .. entregue)

    -- O que este caso existe para prender: no instante do pedido o item ja saiu da origem e ainda
    -- NAO chegou ao destino. Antes do tique agendado os dois numeros mudavam no mesmo instante.
    exigir(quanto(ctx, r.origem, "minecraft:diamond") == 0, "o item deveria ter saido da origem")
    exigir(quanto(ctx, r.destino, "minecraft:diamond") == 0,
           "o item nao pode chegar ao destino no mesmo instante do pedido")

    -- E esta em algum lugar do caminho.
    local em_transito = 0
    for _, cano in ipairs(nos) do
        for _, carga in ipairs(viagem.cargas_em(ctx, cano.x, cano.y, cano.z)) do
            em_transito = em_transito + carga.count
        end
    end
    exigir(em_transito == 12, "os 12 deveriam estar viajando, achei " .. em_transito)
end

TESTES.abastecedor_pede_o_que_falta = function(ctx)
    local r = montar(ctx, 4, 3, "logistica:abastecedor")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:iron_ingot", 64)

    abastecimento.configurar_abastecedor(ctx, r.fim.x, r.fim.y, r.fim.z, "minecraft:iron_ingot", 20)

    local config = abastecimento.configuracao(ctx, r.fim.x, r.fim.y, r.fim.z)
    exigir(config.item == "minecraft:iron_ingot", "a configuracao deveria ter sido gravada")
    exigir(config.alvo == 20, "o alvo deveria ser 20, veio " .. tostring(config.alvo))

    -- Com o bau vazio, falta o alvo inteiro.
    exigir(abastecimento.quanto_falta(ctx, r.fim, config) == 20,
           "deveriam faltar 20 com o bau vazio")

    -- Com o bau cheio do alvo, nao falta nada -- senao ele pediria para sempre.
    ctx.server.insert_into(r.destino.x, r.destino.y, r.destino.z, "minecraft:iron_ingot", 20)
    exigir(abastecimento.quanto_falta(ctx, r.fim, config) == 0,
           "com o alvo atingido nao deveria faltar nada")
end

TESTES.abastecedor_conta_o_que_esta_a_caminho = function(ctx)
    -- Um cano so, e nao quatro. Este caso confere duas vezes, e cada conferida custa uma varredura
    -- mais uma rota: com a rede maior ele estourava o orcamento de 20 ms que a bateria inteira
    -- divide. O que se verifica aqui e a contabilidade do pedido, e ela nao depende da distancia.
    local r = montar(ctx, 6, 1, "logistica:abastecedor")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:gold_ingot", 64)

    abastecimento.configurar_abastecedor(ctx, r.fim.x, r.fim.y, r.fim.z, "minecraft:gold_ingot", 16)
    local config = abastecimento.configuracao(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- Uma conferida coloca 16 na rede.
    abastecimento.conferir(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- A configuracao precisa ser relida: conferir grava a pendencia nela, e a copia de antes nao
    -- tem esse numero. Perguntar a copia velha daria sempre "falta tudo" -- foi o que este caso
    -- acusou na primeira execucao, e o erro era do teste.
    config = abastecimento.configuracao(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- A segunda conferida nao pode pedir de novo: os 16 estao viajando. Este e o caso que separa um
    -- abastecedor de um que enche o bau com varias vezes o alvo.
    exigir(abastecimento.quanto_falta(ctx, r.fim, config) == 0,
           "o que esta a caminho deveria contar como chegado")

    local pediu = abastecimento.conferir(ctx, r.fim.x, r.fim.y, r.fim.z)
    exigir(pediu == 0, "a segunda conferida nao deveria pedir nada, pediu " .. pediu)

    desmontar(ctx, 6, 1)
end

TESTES.satelite_tem_nome = function(ctx)
    local r = montar(ctx, 8, 3, "logistica:satelite")

    exigir(abastecimento.nome_do_satelite(ctx, r.fim.x, r.fim.y, r.fim.z) == nil,
           "um satelite novo nao deveria ter nome")

    abastecimento.nomear_satelite(ctx, r.fim.x, r.fim.y, r.fim.z, "forja")
    exigir(abastecimento.nome_do_satelite(ctx, r.fim.x, r.fim.y, r.fim.z) == "forja",
           "o nome deveria ter sido gravado")

    -- E a rede acha ele pelo nome, que e para isso que o nome serve.
    local nos = rede.varrer(ctx, r.provedor.x, r.provedor.y, r.provedor.z)
    local achado = abastecimento.achar_satelite(ctx, nos, "forja")
    exigir(achado ~= nil, "a rede deveria achar o satelite pelo nome")
    exigir(achado.z == r.fim.z, "achou o satelite errado")

    exigir(abastecimento.achar_satelite(ctx, nos, "nao_existe") == nil,
           "um nome que ninguem usa nao deveria achar nada")

    desmontar(ctx, 8, 3)
end

TESTES.item_nao_desaparece = function(ctx)
    local r = montar(ctx, 10, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:emerald", 10)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    viagem.entregar(ctx, nos, r.fim, "minecraft:emerald", 10)

    -- Soma tudo: bau de origem, bau de destino e o que esta nos canos. Nenhuma esmeralda pode ter
    -- deixado de existir -- e o pior defeito possivel num mod de logistica, e o mais silencioso.
    local total = quanto(ctx, r.origem, "minecraft:emerald")
                  + quanto(ctx, r.destino, "minecraft:emerald")
    for _, cano in ipairs(nos) do
        for _, carga in ipairs(viagem.cargas_em(ctx, cano.x, cano.y, cano.z)) do
            if carga.item == "minecraft:emerald" then total = total + carga.count end
        end
    end
    exigir(total == 10, "deveriam existir 10 esmeraldas em algum lugar, existem " .. total)
end

--- Roda a bateria e escreve o resultado no log.
--
-- **Um caso por tique, e nao todos de uma vez.** Cada callback tem 20 ms, e a bateria inteira num
-- callback so dividia esse orcamento entre todos -- o primeiro caso pesado estourava e os outros
-- levavam a culpa. Montar rede e mexer no mundo custa, e este e o jeito honesto de medir: cada caso
-- recebe o orcamento inteiro, como receberia rodando sozinho no jogo.
local function rodar(ctx, so_este)
    local nomes = {}
    for nome in pairs(TESTES) do nomes[#nomes + 1] = nome end
    table.sort(nomes)

    local fila = {}
    for _, nome in ipairs(nomes) do
        if so_este == nil or so_este == nome then fila[#fila + 1] = nome end
    end

    if #fila == 0 then
        ctx.log.warn("LOGISTICA AUTOTESTE caso desconhecido: " .. tostring(so_este))
        return
    end

    local passaram = 0

    local function proximo(indice)
        if indice > #fila then
            ctx.log.info("LOGISTICA AUTOTESTE " .. passaram .. "/" .. #fila .. " passaram")
            return
        end

        local nome = fila[indice]
        mod.after(indice, function(depois)
            local ok, erro = pcall(function() TESTES[nome](depois) end)
            if ok then
                passaram = passaram + 1
                depois.log.info("LOGISTICA AUTOTESTE OK      " .. nome)
            else
                depois.log.warn("LOGISTICA AUTOTESTE FALHOU  " .. nome .. ": " .. tostring(erro))
            end
            proximo(indice + 1)
        end)
    end

    proximo(1)
end

return { rodar = rodar }
