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
local fabricacao = mod.import("lib/fabricacao.lua")
local chassi = mod.import("lib/chassi.lua")

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

TESTES.fabricar_o_que_falta = function(ctx)
    local r = montar(ctx, 12, 2, "logistica:fabricador")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 16)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- A rede nao tem tabua, mas sabe fazer: uma tora vira quatro.
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:oak_planks", 8)
    exigir(atendido == 8, "deveria dar para fazer 8 tabuas, deu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(#plano.fabricar == 1, "um passo bastava, veio " .. #plano.fabricar)
    exigir(plano.fabricar[1].item == "minecraft:oak_planks", "o passo deveria ser da tabua")
    exigir(plano.fabricar[1].lotes == 2, "oito tabuas sao dois lotes de quatro, veio "
                                         .. plano.fabricar[1].lotes)

    -- E o que sai do mundo sao duas toras, e nao as tabuas: elas nao existem em lugar nenhum.
    exigir(plano.retirar["minecraft:oak_log"] == 2,
           "deveriam sair 2 toras, saem " .. tostring(plano.retirar["minecraft:oak_log"]))
    exigir(plano.retirar["minecraft:oak_planks"] == nil,
           "tabua nao pode sair do estoque: ela esta sendo feita")

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 8, "deveriam ficar prontas 8 tabuas, ficaram " .. pronto)
    exigir(quanto(ctx, r.destino, "minecraft:oak_planks") == 8, "as tabuas deveriam estar no bau")
    exigir(quanto(ctx, r.origem, "minecraft:oak_log") == 14, "deveriam sobrar 14 toras")

    desmontar(ctx, 12, 2)
end

TESTES.fabricar_em_cascata = function(ctx)
    local r = montar(ctx, 14, 2, "logistica:fabricador")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 16)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- O caso que a arvore existe para resolver: a bancada precisa de tabuas, que tambem nao
    -- existem, e que por sua vez precisam de toras -- que existem. Dois niveis.
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:crafting_table", 1)
    exigir(atendido == 1, "deveria dar para fazer a bancada: " .. tostring(motivo))
    exigir(#plano.fabricar == 2, "dois passos: tabua e bancada, veio " .. #plano.fabricar)

    -- Do fundo para a raiz: quem usa vem depois de quem produz. Invertido, a bancada tentaria ser
    -- feita antes de as tabuas existirem.
    exigir(plano.fabricar[1].item == "minecraft:oak_planks", "a tabua vem primeiro")
    exigir(plano.fabricar[2].item == "minecraft:crafting_table", "e a bancada depois")

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronta 1 bancada, ficou " .. pronto)
    exigir(quanto(ctx, r.destino, "minecraft:crafting_table") == 1, "a bancada deveria estar no bau")

    -- E a materia se conserva: uma tora entrou na conta, quinze sobraram.
    exigir(quanto(ctx, r.origem, "minecraft:oak_log") == 15,
           "deveriam sobrar 15 toras, sobraram " .. quanto(ctx, r.origem, "minecraft:oak_log"))

    desmontar(ctx, 14, 2)
end

TESTES.fabricar_sem_material_nao_consome = function(ctx)
    local r = montar(ctx, 16, 2, "logistica:fabricador")
    -- Uma tora so: nao chega para uma bancada, que precisa de quatro tabuas.
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local atendido, motivo = fabricacao.planejar(ctx, nos, "minecraft:crafting_table", 8)

    exigir(atendido < 8, "nao deveria dar para fazer 8 bancadas com uma tora")
    exigir(motivo ~= nil, "um pedido recusado precisa dizer por que")

    -- **Nada foi tirado do lugar.** Um pedido que descobre no meio que falta ingrediente ja
    -- consumiu os outros, e a base fica com material picado e nada pronto. E por isso que planejar
    -- e executar sao separados.
    exigir(quanto(ctx, r.origem, "minecraft:oak_log") == 1,
           "a tora deveria continuar la, planejar nao pode consumir nada")

    desmontar(ctx, 16, 2)
end

TESTES.fabricar_sem_receita_avisa = function(ctx)
    local r = montar(ctx, 18, 2, "logistica:fabricador")
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- Minerio nao se fabrica, se cava. A mensagem precisa dizer isso, e nao ficar em silencio.
    local atendido, motivo = fabricacao.planejar(ctx, nos, "minecraft:diamond_ore", 1)
    exigir(atendido == 0, "nao deveria atender")
    exigir(motivo ~= nil and motivo:find("ninguem sabe fazer") ~= nil,
           "o motivo deveria dizer que ninguem sabe fazer, veio " .. tostring(motivo))

    desmontar(ctx, 18, 2)
end

TESTES.padrao_de_bancada_diz_o_que_sai = function(ctx)
    -- O arranjo decide, e nao o nome do produto. Uma tabua no meio da coluna esquerda nao faz nada;
    -- duas tabuas empilhadas fazem uma vara. E o mesmo par de itens em posicoes diferentes.
    local vazio = { "", "", "", "", "", "", "", "", "" }
    exigir(ctx.server.crafting_result(vazio) == nil, "bancada vazia nao produz nada")

    -- Uma tora sozinha vira quatro tabuas: receita sem formato, e a posicao nao importa. Vale como
    -- caso porque prova que o casamento e o do jogo -- um comparador escrito no mod saberia so as
    -- receitas com formato, e responderia nil aqui.
    local tora = { "", "", "", "", "minecraft:oak_log", "", "", "", "" }
    local tabuas = ctx.server.crafting_result(tora)
    exigir(tabuas ~= nil and tabuas.item == "minecraft:oak_planks",
           "uma tora sozinha deveria fazer tabua, fez " .. tostring(tabuas and tabuas.item))

    local vara = { "minecraft:oak_planks", "", "",
                   "minecraft:oak_planks", "", "",
                   "", "", "" }
    local saida = ctx.server.crafting_result(vara)
    exigir(saida ~= nil, "duas tabuas empilhadas deveriam fazer vara")
    exigir(saida.item == "minecraft:stick",
           "deveria sair vara, saiu " .. tostring(saida and saida.item))
    exigir(saida.count == 4, "uma receita de vara rende 4, rendeu " .. tostring(saida.count))
end

TESTES.fabricar_pelo_padrao = function(ctx)
    local r = montar(ctx, 20, 2, "logistica:fabricador")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 8)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- A rede so tem tora. O padrao pede tabua, que nao existe -- e a arvore desce sozinha ate a
    -- tora, que e o que liga o padrao ao resto do motor.
    local padrao = { "minecraft:oak_planks", "", "",
                     "minecraft:oak_planks", "", "",
                     "", "", "" }

    local total, motivo, plano = fabricacao.planejar_padrao(ctx, nos, padrao, 1)
    exigir(total == 4, "um lote de vara rende 4, veio " .. total .. " (" .. tostring(motivo) .. ")")

    -- Duas tabuas saem de uma tora, e e a tora que sai do bau: a tabua esta sendo feita.
    exigir(plano.retirar["minecraft:oak_log"] == 1,
           "deveria sair 1 tora, sai " .. tostring(plano.retirar["minecraft:oak_log"]))
    exigir(plano.retirar["minecraft:oak_planks"] == nil,
           "tabua nao pode sair do estoque: ela esta sendo feita")

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 4, "deveriam ficar prontas 4 varas, ficaram " .. pronto)
    exigir(quanto(ctx, r.destino, "minecraft:stick") == 4, "as varas deveriam estar no bau")
    exigir(quanto(ctx, r.origem, "minecraft:oak_log") == 7, "deveriam sobrar 7 toras")

    desmontar(ctx, 20, 2)
end

TESTES.padrao_que_nao_faz_nada_nao_consome = function(ctx)
    local r = montar(ctx, 22, 2, "logistica:fabricador")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 4)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- Terra no meio da bancada nao e receita de nada. Recusar antes de planejar e o que impede o
    -- pedido de consumir material para descobrir isso no fim.
    --
    -- Terra, e nao tora: uma tora sozinha vira quatro tabuas, porque receita sem formato ignora a
    -- posicao. Foi o que este caso pegou na primeira escrita, e vale registrar -- "esse arranjo nao
    -- faz nada" e menos comum do que parece.
    local padrao = { "", "", "", "", "minecraft:dirt", "", "", "", "" }
    local total, motivo = fabricacao.planejar_padrao(ctx, nos, padrao, 1)

    exigir(total == 0, "nao deveria produzir nada")
    exigir(motivo ~= nil and motivo:find("nao faz nada") ~= nil,
           "o motivo deveria dizer que o arranjo nao faz nada, veio " .. tostring(motivo))
    exigir(quanto(ctx, r.origem, "minecraft:oak_log") == 4, "nenhuma tora podia ter saido")

    desmontar(ctx, 22, 2)
end

--- Deixa uma carga andar ate o fim da rota, tique a tique.
--
-- A viagem e por tique agendado, e a bateria roda dentro de um callback: sem empurrar a mao, o
-- teste terminaria antes de o item chegar e diria que nada aconteceu.
local function andar(ctx, nos, voltas)
    for _ = 1, voltas do
        for _, cano in ipairs(nos) do
            viagem.passo(ctx, cano.x, cano.y, cano.z)
        end
    end
end

TESTES.chassi_extrai_e_deposita = function(ctx)
    -- O debito que faltava: o chassi so tinha sido verificado a mao.
    local r = montar(ctx, 24, 3, "logistica:chassi")
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- O chassi do fim recebe: um deposito dizendo que barra de ferro mora ali.
    ctx.server.insert_into(r.fim.x, r.fim.y, r.fim.z, "logistica:modulo_deposito", 1)
    chassi.configurar(ctx, r.fim.x, r.fim.y, r.fim.z, 0, { item = "minecraft:iron_ingot" })

    -- E o provedor da origem vira o extrator. Um chassi por cima dele, com o bau ao lado.
    ctx.server.set_block("logistica:chassi", r.provedor.x, r.provedor.y, r.provedor.z)
    ctx.server.insert_into(r.provedor.x, r.provedor.y, r.provedor.z, "logistica:modulo_extrator", 1)
    chassi.configurar(ctx, r.provedor.x, r.provedor.y, r.provedor.z, 0,
                      { item = "minecraft:iron_ingot" })

    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:iron_ingot", 32)

    nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    chassi.passo(ctx, r.provedor.x, r.provedor.y, r.provedor.z)
    andar(ctx, nos, 12)

    -- Saiu do bau de origem sem ninguem pedir, e chegou no bau do deposito.
    exigir(quanto(ctx, r.origem, "minecraft:iron_ingot") == 16,
           "deveriam sobrar 16 barras na origem, sobraram "
           .. quanto(ctx, r.origem, "minecraft:iron_ingot"))
    exigir(quanto(ctx, r.destino, "minecraft:iron_ingot") == 16,
           "16 barras deveriam ter chegado ao destino, chegaram "
           .. quanto(ctx, r.destino, "minecraft:iron_ingot"))

    desmontar(ctx, 24, 3)
end

TESTES.descarte_e_o_ultimo_destino = function(ctx)
    local r = montar(ctx, 26, 3, "logistica:chassi")

    -- O descarte fica no chassi do fim, e um deposito fica num cano do meio. O item tem que ir
    -- para o deposito, e nao ser destruido -- **o descarte e o ultimo destino, nunca o primeiro**.
    ctx.server.insert_into(r.fim.x, r.fim.y, r.fim.z, "logistica:modulo_descarte", 1)

    local meio = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:chassi", meio.x, meio.y, meio.z)
    ctx.server.set_block("minecraft:chest", meio.x + 1, meio.y, meio.z)
    ctx.server.insert_into(meio.x, meio.y, meio.z, "logistica:modulo_deposito", 1)
    chassi.configurar(ctx, meio.x, meio.y, meio.z, 0, { item = "minecraft:emerald" })

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local aceita = chassi.quem_aceita(ctx, nos, "minecraft:emerald")

    exigir(aceita ~= nil, "alguem deveria aceitar a esmeralda")
    exigir(aceita.x == meio.x and aceita.z == meio.z,
           "o deposito deveria ganhar do descarte, ganhou " .. aceita.x .. "," .. aceita.z)

    -- O que ninguem quer, ai sim, vai para o descarte.
    local sobra = chassi.quem_aceita(ctx, nos, "minecraft:dirt")
    exigir(sobra ~= nil and sobra.x == r.fim.x and sobra.z == r.fim.z,
           "o que ninguem aceita deveria ir para o descarte")

    ctx.server.set_block("minecraft:air", meio.x + 1, meio.y, meio.z)
    desmontar(ctx, 26, 3)
end

TESTES.fabricante_vence_a_receita_do_jogo = function(ctx)
    local r = montar(ctx, 28, 3, "logistica:chassi")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 8)

    -- Sem padrao, a arvore usa a receita que o jogo devolve primeiro.
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local semPadrao = select(3, fabricacao.planejar(ctx, nos, "minecraft:stick", 4))

    -- Com o padrao, quem decide e quem montou a base: uma vara de duas tabuas.
    ctx.server.insert_into(r.fim.x, r.fim.y, r.fim.z, "logistica:modulo_fabricante", 1)
    chassi.configurar(ctx, r.fim.x, r.fim.y, r.fim.z, 0, {
        padrao = { "minecraft:oak_planks", "", "",
                   "minecraft:oak_planks", "", "",
                   "", "", "" },
    })

    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 1, "a rede deveria conhecer 1 padrao, conhece " .. #padroes)
    exigir(padroes[1].saida.item == "minecraft:stick",
           "o padrao deveria fazer vara, faz " .. tostring(padroes[1].saida.item))

    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:stick", 4)
    exigir(atendido == 4, "deveria atender 4 varas, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:oak_log"] == 1,
           "deveria sair 1 tora, sai " .. tostring(plano.retirar["minecraft:oak_log"]))
    exigir(semPadrao ~= nil, "o plano sem padrao deveria existir, para a comparacao valer")

    desmontar(ctx, 28, 3)
end

TESTES.extrator_entrega_no_satelite = function(ctx)
    -- A metade que faltava do satelite: ele guardava o nome e ninguem roteava por ele.
    local r = montar(ctx, 30, 3, "logistica:satelite")
    abastecimento.nomear_satelite(ctx, r.fim.x, r.fim.y, r.fim.z, "forja")

    -- O provedor da origem vira um chassi extrator apontado para a forja. **Nenhum deposito
    -- existe na rede** -- e o ponto: com `quem_aceita` nada sairia, porque ninguem declarou querer
    -- barra de ferro. O endereco e sobre o lugar, e nao sobre o item.
    ctx.server.set_block("logistica:chassi", r.provedor.x, r.provedor.y, r.provedor.z)
    ctx.server.insert_into(r.provedor.x, r.provedor.y, r.provedor.z, "logistica:modulo_extrator", 1)
    chassi.configurar(ctx, r.provedor.x, r.provedor.y, r.provedor.z, 0,
                      { item = "minecraft:iron_ingot", satelite = "forja" })

    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:iron_ingot", 32)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    chassi.passo(ctx, r.provedor.x, r.provedor.y, r.provedor.z)
    andar(ctx, nos, 12)

    exigir(quanto(ctx, r.destino, "minecraft:iron_ingot") == 16,
           "16 barras deveriam ter chegado ao bau da forja, chegaram "
           .. quanto(ctx, r.destino, "minecraft:iron_ingot"))

    -- Nome que nao existe nao vira entrega em outro lugar: a producao da forja indo para um bau
    -- qualquer e o tipo de defeito que so aparece quando falta material la na frente.
    chassi.configurar(ctx, r.provedor.x, r.provedor.y, r.provedor.z, 0,
                      { item = "minecraft:iron_ingot", satelite = "fundicao" })
    local antes = quanto(ctx, r.origem, "minecraft:iron_ingot")
    chassi.passo(ctx, r.provedor.x, r.provedor.y, r.provedor.z)
    exigir(quanto(ctx, r.origem, "minecraft:iron_ingot") == antes,
           "satelite inexistente nao podia tirar nada do bau")

    desmontar(ctx, 30, 3)
end

TESTES.provedor_mk2_manda_uma_pilha = function(ctx)
    -- A diferenca entre as versoes e numerica, e e a unica coisa que precisa ser verdade: o Mk1
    -- manda 16 por pedido e o Mk2 manda uma pilha.
    exigir(rede.por_pedido_de("logistica:provedor") == 16,
           "o Mk1 deveria mandar 16, manda " .. rede.por_pedido_de("logistica:provedor"))
    exigir(rede.por_pedido_de("logistica:provedor_mk2") == 64,
           "o Mk2 deveria mandar 64, manda " .. rede.por_pedido_de("logistica:provedor_mk2"))

    local r = montar(ctx, 32, 3, "logistica:terminal")
    ctx.server.set_block("logistica:provedor_mk2", r.provedor.x, r.provedor.y, r.provedor.z)
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:iron_ingot", 64)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- O Mk2 aparece na rede como provedor: se a pergunta "isto e um provedor?" tivesse ficado
    -- espalhada por quatro arquivos, ele apareceria e nunca entregaria.
    local lista = rede.estoque(ctx, nos)
    local achou = false
    for _, entrada in ipairs(lista) do
        if entrada.item == "minecraft:iron_ingot" then achou = entrada.count == 64 end
    end
    exigir(achou, "o Mk2 deveria oferecer as 64 barras a rede")

    local entregue = viagem.entregar(ctx, nos, r.fim, "minecraft:iron_ingot", 64)
    exigir(entregue == 64, "o Mk2 deveria despachar as 64 de uma vez, despachou " .. entregue)

    andar(ctx, nos, 12)
    exigir(quanto(ctx, r.destino, "minecraft:iron_ingot") == 64,
           "as 64 deveriam ter chegado, chegaram "
           .. quanto(ctx, r.destino, "minecraft:iron_ingot"))

    desmontar(ctx, 32, 3)
end

TESTES.fabricador_mk3_desce_mais_fundo = function(ctx)
    local r = montar(ctx, 34, 3, "logistica:fabricador_mk3")
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- O melhor fabricador da rede manda nos limites. Pendurar um Mk3 faz a arvore descer mais
    -- fundo sem mexer em mais nada -- e o que separa as tres versoes do original.
    local limites = rede.limites_de("logistica:fabricador")
    local mk3 = rede.limites_de("logistica:fabricador_mk3")
    exigir(mk3.profundidade > limites.profundidade,
           "o Mk3 deveria descer mais fundo que o Mk1")

    -- E a arvore sente: o plano montado nesta rede usa os limites do Mk3.
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 16)
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:oak_planks", 4)
    exigir(atendido == 4, "deveria atender 4 tabuas (" .. tostring(motivo) .. ")")
    exigir(plano.limites.profundidade == mk3.profundidade,
           "o plano deveria usar os limites do Mk3, usou " .. plano.limites.profundidade)

    desmontar(ctx, 34, 3)
end

TESTES.cano_fabricador_oferece_o_padrao = function(ctx)
    -- O padrao mora nos nove slots do proprio cano, montados na janela do jogo. E o que substituiu
    -- a tela desenhada a mao: sem slot de verdade nao ha como montar um padrao de varios itens.
    local r = montar(ctx, 36, 3, "logistica:fabricador")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 8)

    -- Duas tabuas empilhadas, nos slots 0 e 3 -- a coluna da esquerda da bancada.
    -- `set_slot` porque o padrao e fantasma: `insert_into` passa pelo portao de maquina, que um
    -- inventario fantasma fecha para ninguem apagar o desenho.
    ctx.server.set_slot(r.fim.x, r.fim.y, r.fim.z, 0, "minecraft:oak_planks", 1)
    ctx.server.set_slot(r.fim.x, r.fim.y, r.fim.z, 3, "minecraft:oak_planks", 1)

    local padrao = chassi.padrao_do_bloco(ctx, r.fim.x, r.fim.y, r.fim.z)
    exigir(padrao ~= nil, "o cano deveria ter um padrao")
    exigir(padrao[1] == "minecraft:oak_planks" and padrao[4] == "minecraft:oak_planks",
           "o padrao deveria ter tabua nos slots 1 e 4")

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 1, "a rede deveria conhecer 1 padrao, conhece " .. #padroes)
    exigir(padroes[1].saida.item == "minecraft:stick",
           "o padrao deveria fazer vara, faz " .. tostring(padroes[1].saida.item))

    -- E a arvore usa o padrao do cano: so ha tora na rede, e mesmo assim a vara sai.
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:stick", 4)
    exigir(atendido == 4, "deveria atender 4 varas, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:oak_log"] == 1,
           "deveria sair 1 tora, sai " .. tostring(plano.retirar["minecraft:oak_log"]))

    desmontar(ctx, 36, 3)
end

TESTES.resultado_declarado_vence_o_jogo = function(ctx)
    -- O que abre o sistema para qualquer maquina: o jogo nao precisa conhecer o arranjo.
    --
    -- O fabricador fica **no meio da linha**, sem bau encostado. Isso importa: o bau de destino do
    -- ultimo cano contaria como maquina, e o teste passaria sem provar nada.
    local r = montar(ctx, 38, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 16)

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    -- Uma pedra sozinha no meio nao e receita de bancada nenhuma...
    ctx.server.set_slot(fab.x, fab.y, fab.z, 4, "minecraft:cobblestone", 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    exigir(#chassi.padroes_na_rede(ctx, nos) == 0,
           "sem resultado declarado, o jogo nao conhece esse arranjo")

    -- ...mas um moedor de outro mod faria cascalho. Quem declara e quem sabe da maquina.
    chassi.declarar_resultado(ctx, fab.x, fab.y, fab.z, "minecraft:gravel", 2)

    -- **Sem maquina acoplada, a declaracao nao vale.** Aceita-la seria criar item do nada segundo
    -- uma regra que o proprio jogador escreveu -- duplicacao livre num servidor.
    local achada = chassi.maquina_de(ctx, fab)
    exigir(achada == nil,
           "o fabricador nao devia ter maquina encostada, achou "
           .. (achada and (achada.x .. "," .. achada.y .. "," .. achada.z .. " = "
                           .. tostring(ctx.server.get_block(achada.x, achada.y, achada.z)))
               or "nada"))
    exigir(#chassi.padroes_na_rede(ctx, nos) == 0,
           "sem maquina, o padrao declarado nao podia entrar na lista")
    exigir(select(1, fabricacao.planejar(ctx, nos, "minecraft:gravel", 2)) == 0,
           "sem maquina, o resultado declarado nao podia valer")

    -- A maquina: um bau encostado no fabricador, ja com o produto dentro -- e o que um moedor
    -- teria depois de moer. O cano poe a pedra la e tira o cascalho de la.
    local maquina = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:chest", maquina.x, maquina.y, maquina.z)
    ctx.server.insert_into(maquina.x, maquina.y, maquina.z, "minecraft:gravel", 8)

    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 1, "com maquina, a rede deveria saber fazer, achou " .. #padroes)
    exigir(padroes[1].saida.item == "minecraft:gravel" and padroes[1].saida.count == 2,
           "deveria produzir 2 cascalho, produz " .. tostring(padroes[1].saida.count)
           .. " x " .. tostring(padroes[1].saida.item))

    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:gravel", 2)
    exigir(atendido == 2, "deveria atender 2 cascalho, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:cobblestone"] == 1,
           "deveria sair 1 pedra, sai " .. tostring(plano.retirar["minecraft:cobblestone"]))

    -- O produto sai DA MAQUINA, e nao do nada: o bau tinha 8 cascalhos e fica com 6.
    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 2, "deveriam ficar prontos 2 cascalhos, ficaram " .. pronto)
    exigir(quanto(ctx, maquina, "minecraft:gravel") == 6,
           "a maquina deveria ficar com 6 cascalhos, ficou com "
           .. quanto(ctx, maquina, "minecraft:gravel"))
    exigir(quanto(ctx, maquina, "minecraft:cobblestone") == 1,
           "a pedra deveria ter entrado na maquina, tem "
           .. quanto(ctx, maquina, "minecraft:cobblestone"))

    ctx.server.set_block("minecraft:air", maquina.x, maquina.y, maquina.z)
    desmontar(ctx, 38, 3)
end

TESTES.escolhe_o_ingrediente_que_a_rede_tem = function(ctx)
    -- O caso que apareceu jogando: pedir um bau numa base cheia de carvalho.
    --
    -- A receita do bau aceita tabua de **qualquer** madeira, e a lista da tag vem numa ordem que o
    -- mod nao escolhe. Pegando o primeiro, o plano descia para tora de selva e desistia com
    -- "ninguem sabe fazer" -- com a base tendo o material o tempo todo.
    local r = montar(ctx, 40, 3, "logistica:fabricador")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:oak_log", 16)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:chest", 1)

    exigir(atendido == 1, "deveria dar para fazer um bau com carvalho, deu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")

    -- E o que sai do bau e carvalho, e nao outra madeira qualquer.
    exigir(plano.retirar["minecraft:oak_log"] ~= nil,
           "deveria sair tora de carvalho, saiu " .. tostring(next(plano.retirar)))

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronto 1 bau, ficaram " .. pronto)
    exigir(quanto(ctx, r.destino, "minecraft:chest") == 1, "o bau deveria estar no destino")

    desmontar(ctx, 40, 3)
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
