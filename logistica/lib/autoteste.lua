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
local maquina = mod.import("lib/maquina.lua")
local espera = mod.import("lib/espera.lua")

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

    -- A arvore usa o padrao do cano: so ha tora na rede, e mesmo assim a vara sai. Isso ja prova
    -- que o padrao foi encontrado, entao `padroes_na_rede` nao e chamado a parte -- a chamada
    -- separada custava uma varredura inteira da rede no mesmo callback, e o caso estourava os 20 ms
    -- de forma intermitente, sempre logo depois de o servidor subir, quando o chunk ainda nao esta
    -- carregado. `mapa_de_slots_da_maquina` cobre a lista em separado.
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

TESTES.mapa_de_slots_da_maquina = function(ctx)
    -- O jogador diz o que e cada slot, e o loader nao precisa saber o que e uma fornalha.
    local r = montar(ctx, 42, 3, "logistica:terminal")

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    local forno = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:furnace", forno.x, forno.y, forno.z)

    -- **A fornalha tem tres slots, e dois deles estao vazios.** `container_at` mostraria zero: e
    -- por isso que listar exige saber o tamanho, e nao so o conteudo.
    local slots = maquina.listar(ctx, fab, forno)
    exigir(#slots == 3, "a fornalha deveria ter 3 slots, listou " .. #slots)

    -- E cada um sabe onde aparece na tela da propria fornalha: e o que permite a tela de
    -- configuracao ter a forma da maquina em vez de uma fileira. Sem jogador no servidor a leitura
    -- e recusada, e ai a tela cai na fileira -- por isso o caso aceita as duas respostas.
    local comPosicao = 0
    for _, s in ipairs(slots) do
        if s.x ~= nil and s.y ~= nil then comPosicao = comPosicao + 1 end
    end
    exigir(comPosicao == 0 or comPosicao == 3,
           "ou todos os slots tem posicao ou nenhum tem, veio " .. comPosicao)
    for _, s in ipairs(slots) do
        exigir(s.papel == "nenhum", "slot " .. s.slot .. " nao devia ter papel ainda")
    end

    -- O jogador desenha: minerio no 0, combustivel no 1, produto no 2.
    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "entrada", "minecraft:iron_ore")
    maquina.definir(ctx, fab.x, fab.y, fab.z, 1, "entrada", "minecraft:coal")
    maquina.definir(ctx, fab.x, fab.y, fab.z, 2, "saida")

    -- E cada item acha o proprio lugar. Sem isso o carvao vai para o slot do minerio.
    exigir(maquina.entrada_para(ctx, fab, "minecraft:iron_ore") == 0,
           "o minerio deveria ir para o slot 0")
    exigir(maquina.entrada_para(ctx, fab, "minecraft:coal") == 1,
           "o carvao deveria ir para o slot 1")
    exigir(maquina.saida_para(ctx, fab, "minecraft:iron_ingot") == 2,
           "o produto deveria sair do slot 2")

    -- Um item que ninguem pediu nao vira entrada: nao ha slot livre sem filtro.
    exigir(maquina.entrada_para(ctx, fab, "minecraft:dirt") == nil,
           "terra nao devia ter slot de entrada")

    ctx.server.set_block("minecraft:air", forno.x, forno.y, forno.z)
    desmontar(ctx, 42, 3)
end

TESTES.papel_do_slot_gira_e_guarda_filtro = function(ctx)
    -- O que a tela faz por clique, sem a tela: girar o papel e nao perder o filtro no caminho.
    local r = montar(ctx, 44, 3, "logistica:terminal")

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    local forno = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:furnace", forno.x, forno.y, forno.z)

    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "entrada", "minecraft:iron_ore")

    -- Trocar de entrada para saida mantem o filtro: e o que se espera de um ajuste, e perde-lo
    -- obrigaria a redizer o item a cada clique errado.
    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "saida", "minecraft:iron_ore")
    exigir(maquina.saida_para(ctx, fab, "minecraft:iron_ore") == 0,
           "o slot 0 deveria ser saida de ferro")
    exigir(maquina.entrada_para(ctx, fab, "minecraft:iron_ore") == nil,
           "o slot 0 nao e mais entrada")

    -- E "nenhum" apaga o mapa daquele slot, filtro junto.
    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "nenhum")
    exigir(maquina.saida_para(ctx, fab, "minecraft:iron_ore") == nil,
           "o slot 0 nao devia ter papel nenhum")
    exigir(not maquina.tem_mapa(ctx, fab.x, fab.y, fab.z),
           "o mapa deveria ter ficado vazio")

    ctx.server.set_block("minecraft:air", forno.x, forno.y, forno.z)
    desmontar(ctx, 44, 3)
end

TESTES.mapa_da_maquina_vira_receita = function(ctx)
    -- **O mapa e uma receita.** Dizer "slot 0 recebe pedra, slot 2 devolve cascalho" e dizer que
    -- este cano faz cascalho de pedra -- e era isso que faltava: o mapa existia, a rede nao o lia,
    -- e configurar a maquina inteira nao registrava nada.
    local r = montar(ctx, 46, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 16)

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    -- A maquina, com o produto ja dentro -- e o que um moedor teria depois de moer.
    --
    -- O cascalho vai para o slot 1 **de proposito**: e o slot que o mapa declara como saida. Sem
    -- dizer o slot ele cai no 0, que e a entrada -- e ai a pedra nao tem onde entrar, porque um
    -- slot com item so aceita mais do mesmo. Foi assim que este caso falhou na primeira escrita, e
    -- a recusa estava certa: quem montou a maquina errada fui eu.
    local moedor = { x = fab.x + 1, y = fab.y, z = fab.z }

    -- Ar antes do bau **de proposito**: pousar um bau sobre um bau que ja existe nao zera o
    -- inventario, e o caso deixa restos quando falha no meio -- a limpeza dele mora no fim. O run
    -- seguinte encontrava o slot de entrada ja ocupado e a maquina recusava a pedra, o que parecia
    -- defeito do roteamento e era sujeira do teste anterior.
    ctx.server.set_block("minecraft:air", moedor.x, moedor.y, moedor.z)
    ctx.server.set_block("minecraft:chest", moedor.x, moedor.y, moedor.z)
    ctx.server.insert_into(moedor.x, moedor.y, moedor.z, "minecraft:gravel", 8, 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- Sem mapa e sem padrao, a rede nao sabe fazer nada com esse cano.
    exigir(#chassi.padroes_na_rede(ctx, nos) == 0,
           "sem mapa nem padrao, o cano nao devia oferecer receita")

    -- O jogador mapeia: pedra entra, cascalho sai. Nenhum padrao 3x3 e montado.
    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "entrada", "minecraft:cobblestone")
    maquina.definir(ctx, fab.x, fab.y, fab.z, 1, "saida", "minecraft:gravel")

    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 1, "o mapa deveria virar receita, achou " .. #padroes)
    exigir(padroes[1].saida.item == "minecraft:gravel",
           "deveria produzir cascalho, produz " .. tostring(padroes[1].saida.item))

    -- E a arvore de pedido usa como qualquer outra.
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:gravel", 1)
    exigir(atendido == 1, "deveria atender 1 cascalho, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:cobblestone"] == 1,
           "deveria sair 1 pedra, sai " .. tostring(plano.retirar["minecraft:cobblestone"]))

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronto 1 cascalho, ficaram " .. pronto)
    exigir(quanto(ctx, moedor, "minecraft:cobblestone") == 1,
           "a pedra deveria ter entrado na maquina")
    exigir(quanto(ctx, moedor, "minecraft:gravel") == 7,
           "o cascalho deveria ter saido da maquina, sobrou "
           .. quanto(ctx, moedor, "minecraft:gravel"))

    ctx.server.set_block("minecraft:air", moedor.x, moedor.y, moedor.z)
    desmontar(ctx, 46, 3)
end

TESTES.mapa_conta_quantos_itens_entram = function(ctx)
    -- **Um mapa que so sabe dizer "um de cada" nao descreve quase nenhuma receita.**
    --
    -- Duas entradas com contas diferentes, e a saida com a sua: e o caso que o mapa antigo nao
    -- conseguia escrever, e por isso a rede so alcancava maquina que fosse um para um.
    local r = montar(ctx, 50, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:stick", 16)

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    -- Ar antes do bau: pousar bau sobre bau nao zera o inventario, e um caso que falhe no meio
    -- deixa restos para o run seguinte encontrar no slot de entrada.
    local moedor = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:air", moedor.x, moedor.y, moedor.z)
    ctx.server.set_block("minecraft:chest", moedor.x, moedor.y, moedor.z)
    ctx.server.insert_into(moedor.x, moedor.y, moedor.z, "minecraft:stone_pickaxe", 4, 2)

    -- Tres pedras e duas varas viram uma picareta: as contas sao diferentes entre si e diferentes
    -- de um, que e o que separa este caso do anterior.
    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "entrada", "minecraft:cobblestone", 3)
    maquina.definir(ctx, fab.x, fab.y, fab.z, 1, "entrada", "minecraft:stick", 2)
    maquina.definir(ctx, fab.x, fab.y, fab.z, 2, "saida", "minecraft:stone_pickaxe", 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 1, "o mapa deveria virar receita, achou " .. #padroes)

    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:stone_pickaxe", 1)
    exigir(atendido == 1, "deveria atender 1 picareta, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:cobblestone"] == 3,
           "deveria sair 3 pedras, sai " .. tostring(plano.retirar["minecraft:cobblestone"]))
    exigir(plano.retirar["minecraft:stick"] == 2,
           "deveria sair 2 varas, sai " .. tostring(plano.retirar["minecraft:stick"]))

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronta 1 picareta, ficaram " .. pronto)
    exigir(quanto(ctx, moedor, "minecraft:cobblestone") == 3,
           "as tres pedras deveriam ter entrado, entraram "
           .. quanto(ctx, moedor, "minecraft:cobblestone"))
    exigir(quanto(ctx, moedor, "minecraft:stick") == 2,
           "as duas varas deveriam ter entrado, entraram "
           .. quanto(ctx, moedor, "minecraft:stick"))

    ctx.server.set_block("minecraft:air", moedor.x, moedor.y, moedor.z)
    desmontar(ctx, 50, 3)
end

TESTES.maquina_recebe_um_lote_por_vez = function(ctx)
    -- **Pedir dezesseis nao pode despejar dezesseis lotes na maquina.**
    --
    -- O `1x` do mapa era respeitado por lote, e ninguem limitava quantos lotes iam juntos: pedir
    -- dezesseis carvoes mandava dezesseis troncos para o slot de entrada de uma vez. A maquina
    -- ficava com material para dezesseis ciclos que ela nao ia executar -- a rede pede o produto
    -- no mesmo tique --, e a madeira ficava presa la dentro.
    local r = montar(ctx, 54, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    local moedor = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:air", moedor.x, moedor.y, moedor.z)
    ctx.server.set_block("minecraft:chest", moedor.x, moedor.y, moedor.z)
    ctx.server.insert_into(moedor.x, moedor.y, moedor.z, "minecraft:gravel", 8, 1)

    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "entrada", "minecraft:cobblestone", 1)
    maquina.definir(ctx, fab.x, fab.y, fab.z, 1, "saida", "minecraft:gravel", 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    -- Pede dezesseis; o plano tem que prometer um, e nao dezesseis.
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:gravel", 16)
    exigir(atendido == 1, "com maquina no caminho deveria atender 1 de 16, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:cobblestone"] == 1,
           "deveria sair 1 pedra da rede, sai "
           .. tostring(plano.retirar["minecraft:cobblestone"]))

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronto 1 cascalho, ficaram " .. pronto)

    -- E o teto vale na maquina tambem: uma pedra dentro, e nao dezesseis.
    exigir(quanto(ctx, moedor, "minecraft:cobblestone") == 1,
           "so 1 pedra deveria ter entrado na maquina, entraram "
           .. quanto(ctx, moedor, "minecraft:cobblestone"))

    ctx.server.set_block("minecraft:air", moedor.x, moedor.y, moedor.z)
    desmontar(ctx, 54, 3)
end

TESTES.cadeia_de_duas_maquinas_com_recursao = function(ctx)
    -- **Uma maquina alimentando outra.**
    --
    -- A primeira faz cascalho de pedra; a segunda faz pederneira de cascalho. A rede so tem pedra,
    -- entao atender o pedido exige descer um nivel: fabricar o cascalho para so entao fabricar a
    -- pederneira. E o caso que separa "a arvore resolve receitas" de "a arvore resolve receitas
    -- que passam por maquinas de verdade".
    --
    -- Tudo um para um de proposito: com lotes maiores este caso mediria duas coisas ao mesmo
    -- tempo, e a que falhasse levaria a culpa da outra.
    local r = montar(ctx, 58, 5, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    -- Primeira maquina: pedra -> cascalho.
    local fabA = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fabA.x, fabA.y, fabA.z)
    local moedorA = { x = fabA.x + 1, y = fabA.y, z = fabA.z }
    ctx.server.set_block("minecraft:air", moedorA.x, moedorA.y, moedorA.z)
    ctx.server.set_block("minecraft:chest", moedorA.x, moedorA.y, moedorA.z)
    ctx.server.insert_into(moedorA.x, moedorA.y, moedorA.z, "minecraft:gravel", 8, 1)
    maquina.definir(ctx, fabA.x, fabA.y, fabA.z, 0, "entrada", "minecraft:cobblestone", 1)
    maquina.definir(ctx, fabA.x, fabA.y, fabA.z, 1, "saida", "minecraft:gravel", 1)

    -- Segunda maquina: cascalho -> pederneira.
    local fabB = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 4 }
    ctx.server.set_block("logistica:fabricador", fabB.x, fabB.y, fabB.z)
    local moedorB = { x = fabB.x + 1, y = fabB.y, z = fabB.z }
    ctx.server.set_block("minecraft:air", moedorB.x, moedorB.y, moedorB.z)
    ctx.server.set_block("minecraft:chest", moedorB.x, moedorB.y, moedorB.z)
    ctx.server.insert_into(moedorB.x, moedorB.y, moedorB.z, "minecraft:flint", 8, 1)
    maquina.definir(ctx, fabB.x, fabB.y, fabB.z, 0, "entrada", "minecraft:gravel", 1)
    maquina.definir(ctx, fabB.x, fabB.y, fabB.z, 1, "saida", "minecraft:flint", 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 2, "as duas maquinas deveriam oferecer receita, acharam " .. #padroes)

    -- A rede nao tem cascalho: o unico caminho para a pederneira passa pela primeira maquina.
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:flint", 1)
    exigir(atendido == 1, "deveria atender 1 pederneira, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(#plano.fabricar == 2, "o plano deveria ter dois passos, tem " .. #plano.fabricar)
    exigir(plano.retirar["minecraft:cobblestone"] == 1,
           "deveria sair 1 pedra da rede, sai "
           .. tostring(plano.retirar["minecraft:cobblestone"]))

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronta 1 pederneira, ficaram " .. pronto)

    -- **Cada maquina tem que ter recebido o seu.** Sem isto, o passo do meio existe so no plano: a
    -- pedra sai da rede, a pederneira aparece, e a primeira maquina nunca foi usada.
    exigir(quanto(ctx, moedorA, "minecraft:cobblestone") == 1,
           "a pedra deveria ter entrado na primeira maquina, entraram "
           .. quanto(ctx, moedorA, "minecraft:cobblestone"))
    exigir(quanto(ctx, moedorB, "minecraft:gravel") == 1,
           "o cascalho deveria ter entrado na segunda maquina, entraram "
           .. quanto(ctx, moedorB, "minecraft:gravel"))

    ctx.server.set_block("minecraft:air", moedorA.x, moedorA.y, moedorA.z)
    ctx.server.set_block("minecraft:air", moedorB.x, moedorB.y, moedorB.z)
    desmontar(ctx, 58, 5)
end


TESTES.cadeia_de_tres_maquinas = function(ctx)
    -- **Tres niveis, e nao dois.**
    --
    -- Dois niveis provam que a arvore desce; tres provam que ela desce mais de uma vez, que e onde
    -- um laco escrito para o caso de dois costuma parar. Pedra -> cascalho -> pederneira ->
    -- flecha, com a rede tendo so a pedra.
    local r = montar(ctx, 62, 4, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    local function maquina_em(recuo, entrada, saida, estoque)
        local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - recuo }
        ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

        local caixa = { x = fab.x + 1, y = fab.y, z = fab.z }
        ctx.server.set_block("minecraft:air", caixa.x, caixa.y, caixa.z)
        ctx.server.set_block("minecraft:chest", caixa.x, caixa.y, caixa.z)
        ctx.server.insert_into(caixa.x, caixa.y, caixa.z, estoque, 8, 1)

        maquina.definir_varios(ctx, fab.x, fab.y, fab.z, {
            { slot = 0, papel = "entrada", item = entrada, count = 1 },
            { slot = 1, papel = "saida", item = saida, count = 1 },
        })
        return caixa
    end

    -- Canos vizinhos, e nao de dois em dois: a rede menor cabe no orcamento de 20 ms com folga,
    -- e o que este caso mede -- tres niveis de recursao -- nao depende da distancia entre eles.
    local caixaA = maquina_em(1, "minecraft:cobblestone", "minecraft:gravel", "minecraft:gravel")
    local caixaB = maquina_em(2, "minecraft:gravel", "minecraft:flint", "minecraft:flint")
    local caixaC = maquina_em(3, "minecraft:flint", "minecraft:arrow", "minecraft:arrow")

    -- Montar tres maquinas ja consome o tique; o resto vem no proximo, com orcamento inteiro.
    return function(ctx)
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:arrow", 1)
    exigir(atendido == 1, "deveria atender 1 flecha, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(#plano.fabricar == 3, "o plano deveria ter tres passos, tem " .. #plano.fabricar)

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronta 1 flecha, ficaram " .. pronto)

    -- As tres maquinas tem que ter recebido o seu, e nao so a ultima.
    exigir(quanto(ctx, caixaA, "minecraft:cobblestone") == 1,
           "a pedra deveria estar na primeira maquina, tem "
           .. quanto(ctx, caixaA, "minecraft:cobblestone"))
    exigir(quanto(ctx, caixaB, "minecraft:gravel") == 1,
           "o cascalho deveria estar na segunda maquina, tem "
           .. quanto(ctx, caixaB, "minecraft:gravel"))
    exigir(quanto(ctx, caixaC, "minecraft:flint") == 1,
           "a pederneira deveria estar na terceira maquina, tem "
           .. quanto(ctx, caixaC, "minecraft:flint"))

    ctx.server.set_block("minecraft:air", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.set_block("minecraft:air", caixaB.x, caixaB.y, caixaB.z)
    ctx.server.set_block("minecraft:air", caixaC.x, caixaC.y, caixaC.z)
    desmontar(ctx, 62, 4)
    end
end

TESTES.cadeia_para_quando_a_maquina_do_meio_nao_devolve = function(ctx)
    -- **Uma maquina que ainda nao terminou nao pode virar produto no fim da linha.**
    --
    -- E o caso da fornalha: o material entra, ela leva tempo, e a rede pede o produto no mesmo
    -- tique. Se a cadeia seguisse assim mesmo, a segunda maquina receberia um cascalho que nao
    -- existe e a pederneira sairia do estoque dela -- item aparecendo do nada, de novo.
    local r = montar(ctx, 66, 5, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    local fabA = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fabA.x, fabA.y, fabA.z)
    local caixaA = { x = fabA.x + 1, y = fabA.y, z = fabA.z }
    ctx.server.set_block("minecraft:air", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.set_block("minecraft:chest", caixaA.x, caixaA.y, caixaA.z)
    -- Sem estoque de cascalho: esta maquina nao tem o que devolver.
    maquina.definir(ctx, fabA.x, fabA.y, fabA.z, 0, "entrada", "minecraft:cobblestone", 1)
    maquina.definir(ctx, fabA.x, fabA.y, fabA.z, 1, "saida", "minecraft:gravel", 1)

    local fabB = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 4 }
    ctx.server.set_block("logistica:fabricador", fabB.x, fabB.y, fabB.z)
    local caixaB = { x = fabB.x + 1, y = fabB.y, z = fabB.z }
    ctx.server.set_block("minecraft:air", caixaB.x, caixaB.y, caixaB.z)
    ctx.server.set_block("minecraft:chest", caixaB.x, caixaB.y, caixaB.z)
    ctx.server.insert_into(caixaB.x, caixaB.y, caixaB.z, "minecraft:flint", 8, 1)
    maquina.definir(ctx, fabB.x, fabB.y, fabB.z, 0, "entrada", "minecraft:gravel", 1)
    maquina.definir(ctx, fabB.x, fabB.y, fabB.z, 1, "saida", "minecraft:flint", 1)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local atendido, _, plano = fabricacao.planejar(ctx, nos, "minecraft:flint", 1)
    exigir(atendido == 1, "o plano deveria acreditar que da, atendeu " .. atendido)

    local pronto, erro = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 0, "nao deveria produzir nada, produziu " .. pronto)
    exigir(erro ~= nil and string.find(erro, "ainda nao devolveu") ~= nil,
           "o motivo deveria dizer que a maquina nao devolveu, disse " .. tostring(erro))

    -- E a pederneira da segunda maquina tem que continuar la: ela nao foi produzida.
    exigir(quanto(ctx, caixaB, "minecraft:flint") == 8,
           "a pederneira nao podia ter saido da segunda maquina, sobraram "
           .. quanto(ctx, caixaB, "minecraft:flint"))
    -- A pedra fica na primeira, como uma fornalha faria.
    exigir(quanto(ctx, caixaA, "minecraft:cobblestone") == 1,
           "a pedra deveria ter ficado na primeira maquina, tem "
           .. quanto(ctx, caixaA, "minecraft:cobblestone"))

    ctx.server.set_block("minecraft:air", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.set_block("minecraft:air", caixaB.x, caixaB.y, caixaB.z)
    desmontar(ctx, 66, 5)
end

TESTES.cadeia_multiplica_as_quantidades_do_mapa = function(ctx)
    -- **A conta de um nivel multiplica a do nivel de baixo.**
    --
    -- Uma pederneira come dois cascalhos, e cada cascalho come tres pedras: a rede tem que tirar
    -- seis pedras, e nao duas nem tres. E a conta que um mapa de "um de cada" nunca precisou
    -- fazer, e onde um erro de multiplicacao passa despercebido.
    local r = montar(ctx, 70, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 64)

    local fabA = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 1 }
    ctx.server.set_block("logistica:fabricador", fabA.x, fabA.y, fabA.z)
    local caixaA = { x = fabA.x + 1, y = fabA.y, z = fabA.z }
    ctx.server.set_block("minecraft:air", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.set_block("minecraft:chest", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.insert_into(caixaA.x, caixaA.y, caixaA.z, "minecraft:gravel", 16, 1)
    maquina.definir_varios(ctx, fabA.x, fabA.y, fabA.z, {
        { slot = 0, papel = "entrada", item = "minecraft:cobblestone", count = 3 },
        { slot = 1, papel = "saida", item = "minecraft:gravel", count = 1 },
    })

    local fabB = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fabB.x, fabB.y, fabB.z)
    local caixaB = { x = fabB.x + 1, y = fabB.y, z = fabB.z }
    ctx.server.set_block("minecraft:air", caixaB.x, caixaB.y, caixaB.z)
    ctx.server.set_block("minecraft:chest", caixaB.x, caixaB.y, caixaB.z)
    ctx.server.insert_into(caixaB.x, caixaB.y, caixaB.z, "minecraft:flint", 8, 1)
    maquina.definir_varios(ctx, fabB.x, fabB.y, fabB.z, {
        { slot = 0, papel = "entrada", item = "minecraft:gravel", count = 2 },
        { slot = 1, papel = "saida", item = "minecraft:flint", count = 1 },
    })

    return function(ctx)
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:flint", 1)
    exigir(atendido == 1, "deveria atender 1 pederneira, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")
    exigir(plano.retirar["minecraft:cobblestone"] == 6,
           "duas vezes tres da seis pedras, o plano tirou "
           .. tostring(plano.retirar["minecraft:cobblestone"]))

    ctx.server.set_block("minecraft:air", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.set_block("minecraft:air", caixaB.x, caixaB.y, caixaB.z)
    desmontar(ctx, 70, 3)
    end
end


TESTES.distribuicao_enche_o_minimo_antes_de_espalhar = function(ctx)
    -- **A conta do mapa e um minimo para a maquina rodar, e nao um teto.**
    --
    -- A regra tem duas passadas, e a ordem entre elas e o que importa: primeiro um a um ate cada
    -- slot atingir o minimo, e so depois o excedente. Comecar a encher o segundo slot antes de o
    -- primeiro fechar o minimo daria dois slots incompletos e uma maquina que nao roda.
    local m = mod.import("lib/maquina.lua")
    local duas = { { slot = 0, count = 1 }, { slot = 1, count = 1 } }

    -- Um item so, dois slots pedindo um: vai inteiro para o primeiro.
    local plano, sobra = m.distribuir(duas, 1, 1)
    exigir(plano[1] == 1 and plano[2] == 0,
           "um item devia ir para o primeiro slot, foi " .. plano[1] .. "/" .. plano[2])
    exigir(sobra == 0, "nao devia sobrar nada, sobrou " .. sobra)

    -- Dois itens: um para cada, que e o minimo dos dois.
    plano = m.distribuir(duas, 2, 1)
    exigir(plano[1] == 1 and plano[2] == 1,
           "dois itens deviam ir um para cada, foram " .. plano[1] .. "/" .. plano[2])

    -- Seis itens: os dois minimos primeiro, e o excedente espalhado.
    plano = m.distribuir(duas, 6, 1)
    exigir(plano[1] + plano[2] == 6, "os seis deviam entrar, entraram "
                                     .. (plano[1] + plano[2]))
    exigir(plano[1] >= 1 and plano[2] >= 1,
           "os dois minimos deviam estar garantidos, ficou " .. plano[1] .. "/" .. plano[2])

    -- Minimos diferentes: tres num lado e um no outro.
    local desiguais = { { slot = 0, count = 3 }, { slot = 1, count = 1 } }
    plano = m.distribuir(desiguais, 4, 1)
    exigir(plano[1] == 3 and plano[2] == 1,
           "com quatro itens cada slot devia receber o seu minimo, ficou "
           .. plano[1] .. "/" .. plano[2])

    -- Material a menos que o minimo total: o primeiro fecha o dele antes de o segundo comecar.
    plano = m.distribuir(desiguais, 2, 1)
    exigir(plano[1] + plano[2] == 2, "os dois itens deviam ser distribuidos, foram "
                                     .. (plano[1] + plano[2]))

    -- Sem slot nenhum, tudo sobra: e o sinal de que a maquina nao tem onde receber.
    local nenhum
    plano, nenhum = m.distribuir({}, 5, 1)
    exigir(nenhum == 5, "sem slot mapeado os cinco deviam sobrar, sobraram " .. nenhum)

    -- E a conta e por lote: dois lotes de um minimo de dois pedem quatro.
    local umSlot = { { slot = 0, count = 2 } }
    plano = m.distribuir(umSlot, 4, 2)
    exigir(plano[1] == 4, "dois lotes de dois deviam pedir quatro, pediram " .. plano[1])
end

TESTES.duas_entradas_do_mesmo_item_recebem_cada_uma = function(ctx)
    -- **Duas entradas do mesmo item precisam ser abastecidas as duas.**
    --
    -- A busca antiga devolvia um slot so, escolhido com `pairs` -- que em Lua nao tem ordem. Tudo
    -- caia sempre na mesma entrada e a outra ficava vazia; qual das duas nem era estavel entre
    -- execucoes. Este caso monta exatamente isso e confere os dois slots.
    local r = montar(ctx, 74, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 2 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    local caixa = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:air", caixa.x, caixa.y, caixa.z)
    ctx.server.set_block("minecraft:chest", caixa.x, caixa.y, caixa.z)
    ctx.server.insert_into(caixa.x, caixa.y, caixa.z, "minecraft:gravel", 8, 2)

    -- Dois slots de entrada para o mesmo item, um em cada lado.
    maquina.definir(ctx, fab.x, fab.y, fab.z, 0, "entrada", "minecraft:cobblestone", 1)
    maquina.definir(ctx, fab.x, fab.y, fab.z, 1, "entrada", "minecraft:cobblestone", 1)
    maquina.definir(ctx, fab.x, fab.y, fab.z, 2, "saida", "minecraft:gravel", 1)

    -- A ordem tem que ser crescente e estavel, e nao o que o `pairs` devolver.
    local entradas = maquina.entradas_para(ctx, fab, "minecraft:cobblestone")
    exigir(#entradas == 2, "deveria achar duas entradas, achou " .. #entradas)
    exigir(entradas[1].slot == 0 and entradas[2].slot == 1,
           "as entradas deveriam vir em ordem de slot, vieram "
           .. entradas[1].slot .. " e " .. entradas[2].slot)

    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)
    local atendido, motivo, plano = fabricacao.planejar(ctx, nos, "minecraft:gravel", 1)
    exigir(atendido == 1, "deveria atender 1 cascalho, atendeu " .. atendido
                          .. " (" .. tostring(motivo) .. ")")

    local pronto = fabricacao.executar(ctx, nos, plano, r.fim)
    exigir(pronto == 1, "deveria ficar pronto 1 cascalho, ficaram " .. pronto)

    -- Duas pedras pedidas, uma em cada slot -- e nao duas empilhadas num so.
    local no_zero, no_um = 0, 0
    for _, entrada in ipairs(ctx.server.container_at(caixa.x, caixa.y, caixa.z)) do
        if entrada.item == "minecraft:cobblestone" then
            if entrada.slot == 0 then no_zero = entrada.count end
            if entrada.slot == 1 then no_um = entrada.count end
        end
    end
    exigir(no_zero == 1 and no_um == 1,
           "cada entrada deveria ter recebido uma pedra, receberam "
           .. no_zero .. " e " .. no_um)

    ctx.server.set_block("minecraft:air", caixa.x, caixa.y, caixa.z)
    desmontar(ctx, 74, 3)
end


TESTES.pedidos_repetidos_entram_na_fila_do_cano = function(ctx)
    -- **Tres pedidos do mesmo item viram tres ordens, e nao um atendido e dois perdidos.**
    --
    -- Com uma espera unica por cano, o primeiro pedido ocupava o cano e os outros eram recusados --
    -- enquanto o material deles ja estava dentro da maquina, produzindo para ninguem recolher. E o
    -- desenho do original: uma fila de ordens no cano, cada uma entregue quando ficar pronta.
    local r = montar(ctx, 78, 3, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - 1 }
    ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

    -- Maquina sem estoque de saida: ela recebe e nao devolve, que e o que poe o cano em espera.
    local caixa = { x = fab.x + 1, y = fab.y, z = fab.z }
    ctx.server.set_block("minecraft:air", caixa.x, caixa.y, caixa.z)
    ctx.server.set_block("minecraft:chest", caixa.x, caixa.y, caixa.z)

    maquina.definir_varios(ctx, fab.x, fab.y, fab.z, {
        { slot = 0, papel = "entrada", item = "minecraft:cobblestone", count = 1 },
        { slot = 1, papel = "saida", item = "minecraft:gravel", count = 1 },
    })

    return function(ctx)
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    for volta = 1, 3 do
        local _, _, plano = fabricacao.planejar(ctx, nos, "minecraft:gravel", 1)
        local pronto, motivo = fabricacao.executar(ctx, nos, plano, r.fim)
        exigir(pronto == 0, "a maquina nao tem o que devolver, nao devia produzir")
        exigir(motivo ~= nil and string.find(motivo, "processando") ~= nil,
               "o motivo devia dizer que esta processando, disse " .. tostring(motivo))
        exigir(espera.pendentes(ctx, fab.x, fab.y, fab.z) == volta,
               "a fila devia ter " .. volta .. " ordem(ns), tem "
               .. espera.pendentes(ctx, fab.x, fab.y, fab.z))
    end

    -- Cada pedido levou o seu material: tres ordens, tres pedras dentro da maquina.
    exigir(quanto(ctx, caixa, "minecraft:cobblestone") == 3,
           "as tres pedras deviam ter entrado, entraram "
           .. quanto(ctx, caixa, "minecraft:cobblestone"))

    -- A maquina termina uma: a fila anda e a ordem sai.
    ctx.server.insert_into(caixa.x, caixa.y, caixa.z, "minecraft:gravel", 1, 1)
    espera.conferir(ctx, fab.x, fab.y, fab.z)
    exigir(espera.pendentes(ctx, fab.x, fab.y, fab.z) == 2,
           "depois de uma entrega deviam sobrar duas ordens, sobraram "
           .. espera.pendentes(ctx, fab.x, fab.y, fab.z))
    exigir(quanto(ctx, r.destino, "minecraft:gravel") == 1,
           "o cascalho devia ter sido entregue no destino, chegaram "
           .. quanto(ctx, r.destino, "minecraft:gravel"))

    ctx.server.set_block("minecraft:air", fab.x, fab.y, fab.z)
    ctx.server.set_block("minecraft:air", caixa.x, caixa.y, caixa.z)
    desmontar(ctx, 78, 3)
    end
end


TESTES.duas_maquinas_iguais_dividem_o_trabalho = function(ctx)
    -- **Duas maquinas que fazem a mesma coisa tem que trabalhar as duas.**
    --
    -- O planejador pegava a primeira oferta que servia e parava ali: montar uma segunda fornalha
    -- nao fabricava mais rapido, so gastava ferro. Pior, com a fila da primeira cheia o pedido era
    -- recusado com a segunda ociosa do lado. Agora vence a de fila mais curta, e pedidos seguidos
    -- se alternam sozinhos.
    local r = montar(ctx, 82, 4, "logistica:terminal")
    ctx.server.insert_into(r.origem.x, r.origem.y, r.origem.z, "minecraft:cobblestone", 32)

    local function maquina_em(recuo)
        local fab = { x = r.fim.x, y = r.fim.y, z = r.fim.z - recuo }
        ctx.server.set_block("logistica:fabricador", fab.x, fab.y, fab.z)

        -- Sem estoque de saida: as duas recebem e nao devolvem, entao as duas ficam com fila.
        local caixa = { x = fab.x + 1, y = fab.y, z = fab.z }
        ctx.server.set_block("minecraft:air", caixa.x, caixa.y, caixa.z)
        ctx.server.set_block("minecraft:chest", caixa.x, caixa.y, caixa.z)

        maquina.definir_varios(ctx, fab.x, fab.y, fab.z, {
            { slot = 0, papel = "entrada", item = "minecraft:cobblestone", count = 1 },
            { slot = 1, papel = "saida", item = "minecraft:gravel", count = 1 },
        })
        return fab, caixa
    end

    local fabA, caixaA = maquina_em(1)
    local fabB, caixaB = maquina_em(2)

    return function(ctx)
    local nos = rede.varrer(ctx, r.fim.x, r.fim.y, r.fim.z)

    local padroes = chassi.padroes_na_rede(ctx, nos)
    exigir(#padroes == 2, "as duas maquinas deviam oferecer a receita, acharam " .. #padroes)

    -- Quatro pedidos: com o desempate por fila, dois vao para cada uma.
    for _ = 1, 4 do
        local _, _, plano = fabricacao.planejar(ctx, nos, "minecraft:gravel", 1)
        fabricacao.executar(ctx, nos, plano, r.fim)
    end

    local naA = espera.pendentes(ctx, fabA.x, fabA.y, fabA.z)
    local naB = espera.pendentes(ctx, fabB.x, fabB.y, fabB.z)
    exigir(naA + naB == 4, "as quatro ordens deviam existir, existem " .. (naA + naB))
    exigir(naA == 2 and naB == 2,
           "as quatro deviam ficar dois a dois, ficaram " .. naA .. " e " .. naB)

    -- E o material seguiu a ordem: cada maquina recebeu o que a fila dela pediu.
    exigir(quanto(ctx, caixaA, "minecraft:cobblestone") == 2,
           "a primeira devia ter duas pedras, tem " .. quanto(ctx, caixaA, "minecraft:cobblestone"))
    exigir(quanto(ctx, caixaB, "minecraft:cobblestone") == 2,
           "a segunda devia ter duas pedras, tem " .. quanto(ctx, caixaB, "minecraft:cobblestone"))

    ctx.server.set_block("minecraft:air", fabA.x, fabA.y, fabA.z)
    ctx.server.set_block("minecraft:air", fabB.x, fabB.y, fabB.z)
    ctx.server.set_block("minecraft:air", caixaA.x, caixaA.y, caixaA.z)
    ctx.server.set_block("minecraft:air", caixaB.x, caixaB.y, caixaB.z)
    desmontar(ctx, 82, 4)
    end
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

        -- **Um caso pode ocupar mais de um tique.**
        --
        -- Devolvendo uma funcao, ele diz "o resto vem no proximo tique" e ganha outro orcamento
        -- inteiro. Sem isso, um caso que monta rede, configura tres maquinas e ainda planeja e
        -- executa nao cabia nos 20 ms -- e o estouro caia num laco barato qualquer, que e onde o
        -- contador de instrucoes bate, dando a impressao de defeito naquele trecho.
        --
        -- Continua um caso por tique: o que muda e que agora "um caso" pode ter mais de um passo.
        local function passo(seguir, tique)
            mod.after(tique, function(depois)
                local ok, resto = pcall(function() return seguir(depois) end)

                if ok and type(resto) == "function" then
                    passo(resto, 1)
                    return
                end

                if ok then
                    passaram = passaram + 1
                    depois.log.info("LOGISTICA AUTOTESTE OK      " .. nome)
                else
                    depois.log.warn("LOGISTICA AUTOTESTE FALHOU  " .. nome .. ": "
                                    .. tostring(resto))
                end
                proximo(indice + 1)
            end)
        end

        passo(TESTES[nome], indice)
    end

    proximo(1)
end

return { rodar = rodar }
