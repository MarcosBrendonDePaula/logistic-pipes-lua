-- Uma rede de canos que encontra e entrega itens, no espirito do Logistic Pipes.
--
-- O original tem dezenas de canos; este porte fica nos tres que formam o ciclo completo, que sao os
-- que a descricao do proprio mod chama de:
--
--   Cano Logistico   -- "routes items around the network"
--   Cano Provedor    -- "attaches to an inventory, sends 16 items into the network on request"
--   Terminal         -- "lets you manually request items... put a chest on the pipe to catch items"
--
-- A ideia central e essa: o terminal pergunta a rede o que existe, voce escolhe, e o provedor tira
-- do bau ao lado dele e manda para o bau ao lado do terminal. Tudo o mais do mod original --
-- crafting, satelite, chassi, modulos -- e construido em cima disso.
--
-- Por que portar um mod que parou.
--
-- O Logistic Pipes nao parou por falta de ideia: acompanhar as versoes do Minecraft em Java custa
-- caro, porque cada atualizacao mexe em registro, em renderizacao e em rede. Um mod declarativo nao
-- paga esse preco -- quem acompanha a versao e o loader, e o mod continua sendo o mesmo JSON e o
-- mesmo Lua. E a razao de este exemplo existir aqui em vez de ser so uma demonstracao.
--
-- Ele tambem e um teste de esforco: usa bloco declarado, inventario de terceiros, modulo, estado
-- por jogador e tela de uma vez so. O que faltar na API aparece aqui antes de aparecer para quem
-- escreve um mod de verdade.

local terminal = mod.import("lib/terminal.lua")
local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")
local abastecimento = mod.import("lib/abastecimento.lua")
local autoteste = mod.import("lib/autoteste.lua")
local fabricacao = mod.import("lib/fabricacao.lua")
local chassi = mod.import("lib/chassi.lua")
local viagem = mod.import("lib/viagem.lua")

--- Le a receita da bancada encostada num fabricador e desenha nos slots dele.
--
-- Uma funcao, e nao so um comando: o botao da janela declarada chama a mesma coisa. Duas copias da
-- leitura divergiriam no primeiro ajuste, e o botao passaria a fazer algo diferente do comando com
-- o mesmo nome.
--
-- Devolve `ok, mensagem`.
local function importar_padrao(ctx, x, y, z)
    local bloco = ctx.server.get_block(x, y, z)
    if bloco == nil or string.sub(bloco, 1, 20) ~= "logistica:fabricador" then
        return false, "LOGISTICA nao ha fabricador em " .. x .. "," .. y .. "," .. z
    end

    local lados = {
        { dx = 0, dy = 0, dz = -1 }, { dx = 0, dy = 0, dz = 1 },
        { dx = -1, dy = 0, dz = 0 }, { dx = 1, dy = 0, dz = 0 },
        { dx = 0, dy = 1, dz = 0 }, { dx = 0, dy = -1, dz = 0 },
    }

    for _, lado in ipairs(lados) do
        local vx, vy, vz = x + lado.dx, y + lado.dy, z + lado.dz

        -- Qualquer vizinho com nove slots serve. Nao exige bancada do jogo: um bloco de outro mod
        -- que guarde um arranjo 3x3 responde a mesma pergunta, e recusar por id fecharia a porta
        -- justamente para o caso que faz um modpack valer a pena.
        local conteudo = nil
        local ok = pcall(function() conteudo = ctx.server.container_at(vx, vy, vz) end)

        if ok and conteudo ~= nil and #conteudo > 0 then
            local maiorSlot = -1
            for _, entrada in ipairs(conteudo) do
                if entrada.slot > maiorSlot then maiorSlot = entrada.slot end
            end

            if maiorSlot >= 0 and maiorSlot <= 8 then
                local padrao = {}
                for slot = 1, 9 do padrao[slot] = "" end
                for _, entrada in ipairs(conteudo) do
                    padrao[entrada.slot + 1] = entrada.item
                end

                local saiu, saida = pcall(function()
                    return ctx.server.crafting_result(padrao)
                end)
                if not saiu then saida = nil end

                -- `set_slot` e nao `insert_into`: o inventario e fantasma e recusa maquina de
                -- proposito, e a versao que acrescenta passa por esse portao.
                for slot = 0, 8 do
                    ctx.server.set_slot(x, y, z, slot, padrao[slot + 1], 1)
                end

                if saida ~= nil then
                    ctx.server.set_slot(x, y, z, 9, saida.item, saida.count)
                    return true, "LOGISTICA padrao importado de " .. vx .. "," .. vy .. "," .. vz
                                 .. ": faz " .. saida.count .. " x " .. saida.item
                end

                -- Sem receita conhecida o padrao entra do mesmo jeito: quem sabe da maquina e o
                -- jogador, e ele diz o que sai pelo slot de saida ou pelo comando.
                return false, "LOGISTICA padrao importado, mas o jogo nao conhece esse arranjo:"
                              .. " ponha o resultado no slot de saida"
            end
        end
    end

    return false, "LOGISTICA nenhuma bancada montada encostada neste cano"
end

mod.screen("terminal", terminal.evento)

-- O botao da janela declarada do fabricador.
--
-- O nome da tela e o id do bloco, e o valor e a posicao: sem ela o script saberia que alguem clicou
-- em "importar" e nao em qual maquina. E o mesmo canal dos eventos de tela desenhada -- um botao e
-- um botao, e dois canais dariam dois lugares para tratar a mesma coisa.
local function botao_do_fabricador(ctx)
    if ctx.ui.action ~= "click" or ctx.ui.element ~= "importar" then return end

    local x, y, z = string.match(ctx.ui.value or "", "(-?%d+),(-?%d+),(-?%d+)")
    if x == nil then return end

    local ok, mensagem = importar_padrao(ctx, tonumber(x), tonumber(y), tonumber(z))
    if ctx.player ~= nil then ctx.player.send_message(mensagem) end
    if ok then ctx.log.info(mensagem) else ctx.log.warn(mensagem) end
end

mod.screen("fabricador", botao_do_fabricador)
mod.screen("fabricador_mk2", botao_do_fabricador)
mod.screen("fabricador_mk3", botao_do_fabricador)

-- Um comando para conferir a rede sem estar no jogo.
--
-- O terminal abre por clique, e clique exige alguem no mundo. Isso deixaria a rede sem nenhuma
-- verificacao automatica -- e e justamente a parte que mais tem como quebrar em silencio. O
-- comando faz as mesmas perguntas que a tela faz, e responde no log.
--
--   /mod logistica ver <x> <y> <z>                        o que a rede enxerga dali
--   /mod logistica pedir <x> <y> <z> <item>               entrega, como o botao da tela faria
--   /mod logistica satelite <x> <y> <z> <nome>            da nome a um satelite
--   /mod logistica abastecer <x> <y> <z> <item> <qtd>     mantem um bau em estoque
--   /mod logistica fabricar <x> <y> <z> <item> [qtd]      pede a rede que fabrique
--   /mod logistica modulo <x> <y> <z> <slot> <item> [qtd]  configura um slot do chassi
--   /mod logistica padrao <x> <y> <z> <slot> <linhas>   padrao de bancada de um fabricante
--   /mod logistica destino <x> <y> <z> <slot> [nome]   extrator entrega num satelite
--   /mod logistica importar <x> <y> <z>                le a receita da bancada ao lado
--   /mod logistica resultado <x> <y> <z> <item> [qtd] declara o que o cano produz
--   /mod logistica fabricantes <x> <y> <z>            quem sabe fabricar o que, na rede
--   /mod logistica estado <x> <y> <z>                     conexoes daquele cano, lado a lado
--   /mod logistica mapa <x> <y> <z>                       a rede toda, e os canos soltos
--   /mod logistica autoteste [caso]                       roda a bateria de verificacao
--- Responde a quem pediu.
--
-- `ctx.log` escreve no log do servidor, e quem digitou o comando no jogo nao ve nada -- foi
-- exatamente assim que os comandos deste mod pareceram nao funcionar: eles rodavam, e a resposta
-- ia para um arquivo que ninguem estava olhando.
--
-- O log continua recebendo, porque o comando tambem e usado pelo console do servidor, onde nao ha
-- jogador nenhum.
local function responder(ctx, texto, aviso)
    if aviso then ctx.log.warn(texto) else ctx.log.info(texto) end
    if ctx.player ~= nil then ctx.player.send_message(texto) end
end

mod.command("logistica", function(ctx)
    local args = ctx.argv or {}
    local acao = ctx.subcommand or "ver"

    -- A bateria nao precisa de coordenadas: ela monta as proprias redes num canto do mundo. Por
    -- isso ela vem antes da leitura dos argumentos, que exige x, y e z.
    if acao == "autoteste" then
        autoteste.rodar(ctx, args[2])
        return
    end

    local x = tonumber(args[2])
    local y = tonumber(args[3])
    local z = tonumber(args[4])

    -- Sem coordenada, vale o bloco que quem digitou esta olhando.
    --
    -- Digitar tres numeros exige abrir o F3 e anotar o que se esta vendo na frente. Mirar e o gesto
    -- natural, e os argumentos seguintes andam uma casa para tras quando a mira decide.
    local mirou = false
    if (x == nil or y == nil or z == nil) and ctx.player ~= nil then
        local alvo = ctx.player.looking_at()
        if alvo ~= nil then
            x, y, z = alvo.x, alvo.y, alvo.z
            mirou = true

            -- O resto dos argumentos vem logo depois da acao, e nao depois das coordenadas.
            local deslocado = { args[1] }
            for i = 2, #args do deslocado[i + 3] = args[i] end
            args = deslocado
        end
    end

    if x == nil or y == nil or z == nil then
        responder(ctx, "uso: /mod logistica <acao> [<x> <y> <z>] [...]"
                        .. " -- sem coordenada, vale o bloco que voce esta olhando", true)
        return
    end

    -- Configurar um satelite ou um abastecedor nao precisa varrer a rede: os dois so escrevem na
    -- posicao do proprio cano.
    if acao == "satelite" then
        local nome = args[5]
        if nome == nil then
            responder(ctx, "uso: /mod logistica satelite <x> <y> <z> <nome>", true)
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:satelite" then
            responder(ctx, "LOGISTICA nao ha satelite em " .. x .. "," .. y .. "," .. z, true)
            return
        end
        abastecimento.nomear_satelite(ctx, x, y, z, nome)
        responder(ctx, "LOGISTICA satelite=" .. nome .. " em " .. x .. "," .. y .. "," .. z)
        return
    end

    if acao == "abastecer" then
        local item = args[5]
        local alvo = tonumber(args[6])
        if item == nil or alvo == nil then
            responder(ctx, "uso: /mod logistica abastecer <x> <y> <z> <item> <quantidade>", true)
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:abastecedor" then
            responder(ctx, "LOGISTICA nao ha abastecedor em " .. x .. "," .. y .. "," .. z, true)
            return
        end
        abastecimento.configurar_abastecedor(ctx, x, y, z, item, alvo)
        responder(ctx, "LOGISTICA abastecedor=" .. item .. " alvo=" .. alvo)
        return
    end

    if acao == "estado" then
        -- O estado de conexao de um cano, lado a lado.
        --
        -- Existe porque o desenho nao esta confiavel: sem ver o braco crescer, nao da para saber se
        -- o cano ligou no bau ou nao. Isto pergunta ao mundo, que e a fonte que importa -- o
        -- desenho le esse mesmo estado.
        local bloco = ctx.server.get_block(x, y, z)
        responder(ctx, "LOGISTICA " .. bloco .. " em " .. x .. "," .. y .. "," .. z)

        local lados = {
            { nome = "norte", dx = 0, dy = 0, dz = -1 },
            { nome = "sul",   dx = 0, dy = 0, dz = 1 },
            { nome = "oeste", dx = -1, dy = 0, dz = 0 },
            { nome = "leste", dx = 1, dy = 0, dz = 0 },
            { nome = "cima",  dx = 0, dy = 1, dz = 0 },
            { nome = "baixo", dx = 0, dy = -1, dz = 0 },
        }

        for _, lado in ipairs(lados) do
            local vx, vy, vz = x + lado.dx, y + lado.dy, z + lado.dz
            local vizinho = ctx.server.get_block(vx, vy, vz)

            -- Um cano conecta a cano; um bau nao vira conexao de forma, mas E alcancavel pela
            -- rede. Sao duas coisas diferentes, e confundi-las e o que faz parecer que o cano
            -- "nao ligou" no bau: ele nunca cresce braco para bau nenhum.
            local ehCano = rede.e_cano(ctx, vx, vy, vz)
            local temInventario = false
            for _, capacidade in ipairs(ctx.server.capabilities_at(vx, vy, vz)) do
                if capacidade == "items" then temInventario = true end
            end

            local marca = "  " .. lado.nome .. ": " .. vizinho
            if ehCano then marca = marca .. "  [cano: braco]"
            elseif temInventario then marca = marca .. "  [inventario: a rede alcanca, sem braco]"
            end
            responder(ctx, marca)
        end

        local nos = rede.varrer(ctx, x, y, z)
        responder(ctx, "LOGISTICA a rede daqui tem " .. #nos .. " cano(s)")
        return
    end

    if acao == "mapa" then
        -- A rede inteira de uma vez, e o que ficou de fora dela.
        --
        -- O `estado` responde por um cano; para descobrir POR QUE dois trechos nao se falam, um
        -- cano de cada vez nao serve -- a resposta esta no cano que nao aparece em lista nenhuma.
        -- Este dump varre a rede, mostra a vizinhanca de cada no, e depois procura na caixa que
        -- envolve tudo os canos que existem no mundo e nao entraram: sao esses os desligados.
        local nos, cortou = rede.varrer(ctx, x, y, z)

        responder(ctx, "LOGISTICA mapa a partir de " .. x .. "," .. y .. "," .. z
                        .. " -- " .. #nos .. " cano(s)"
                        .. (cortou and " (cortado no teto)" or ""))

        local dentro = {}
        local menor = { x = x, y = y, z = z }
        local maior = { x = x, y = y, z = z }

        for _, no in ipairs(nos) do
            dentro[no.x .. "," .. no.y .. "," .. no.z] = true
            if no.x < menor.x then menor.x = no.x end
            if no.y < menor.y then menor.y = no.y end
            if no.z < menor.z then menor.z = no.z end
            if no.x > maior.x then maior.x = no.x end
            if no.y > maior.y then maior.y = no.y end
            if no.z > maior.z then maior.z = no.z end
        end

        local lados = {
            { nome = "N", dx = 0, dy = 0, dz = -1 },
            { nome = "S", dx = 0, dy = 0, dz = 1 },
            { nome = "O", dx = -1, dy = 0, dz = 0 },
            { nome = "L", dx = 1, dy = 0, dz = 0 },
            { nome = "C", dx = 0, dy = 1, dz = 0 },
            { nome = "B", dx = 0, dy = -1, dz = 0 },
        }

        --- Se ha inventario naquela posicao.
        local function tem_inventario(px, py, pz)
            for _, capacidade in ipairs(ctx.server.capabilities_at(px, py, pz)) do
                if capacidade == "items" then return true end
            end
            return false
        end

        -- Uma linha por cano. O papel de cada um vem junto: provedor e terminal sao os dois que
        -- decidem se um pedido funciona, e procura-los na lista inteira e o que se estava fazendo
        -- a mao.
        for _, no in ipairs(nos) do
            local papel = string.gsub(no.bloco, "^logistica:", "")
            local linha = "  " .. no.x .. "," .. no.y .. "," .. no.z .. " " .. papel .. " ["

            for _, lado in ipairs(lados) do
                local vx, vy, vz = no.x + lado.dx, no.y + lado.dy, no.z + lado.dz
                if dentro[vx .. "," .. vy .. "," .. vz] then
                    linha = linha .. lado.nome
                elseif tem_inventario(vx, vy, vz) then
                    linha = linha .. string.lower(lado.nome)
                else
                    linha = linha .. "-"
                end
            end

            responder(ctx, linha .. "]")
        end

        responder(ctx, "LOGISTICA maiuscula=cano da rede, minuscula=inventario, tracinho=nada")

        -- Agora os canos que existem por perto e nao entraram na rede.
        --
        -- A caixa cresce um bloco para cada lado porque um cano vizinho da caixa e justamente o
        -- caso interessante: ele encosta na rede e mesmo assim nao entrou.
        local volume = (maior.x - menor.x + 3) * (maior.y - menor.y + 3) * (maior.z - menor.z + 3)

        -- O teto existe pelo orcamento de 20 ms do callback: cada posicao e uma leitura de bloco,
        -- e uma rede espalhada geraria uma caixa enorme quase toda vazia.
        if volume > 4096 then
            responder(ctx, "LOGISTICA area grande demais (" .. volume
                            .. " blocos) para procurar cano solto", true)
            return
        end

        local soltos = 0
        for px = menor.x - 1, maior.x + 1 do
            for py = menor.y - 1, maior.y + 1 do
                for pz = menor.z - 1, maior.z + 1 do
                    if not dentro[px .. "," .. py .. "," .. pz]
                       and rede.e_cano(ctx, px, py, pz) then
                        soltos = soltos + 1
                        if soltos <= 20 then
                            local papel = string.gsub(ctx.server.get_block(px, py, pz),
                                                      "^logistica:", "")
                            responder(ctx, "  SOLTO " .. px .. "," .. py .. "," .. pz
                                            .. " " .. papel, true)
                        end
                    end
                end
            end
        end

        if soltos == 0 then
            responder(ctx, "LOGISTICA nenhum cano solto na area -- a rede e tudo que ha aqui")
        else
            responder(ctx, "LOGISTICA " .. soltos .. " cano(s) fora da rede"
                            .. (soltos > 20 and " (mostrando 20)" or ""), true)
        end
        return
    end
    if acao == "destino" then
        -- Manda um slot extrator entregar num satelite nomeado, em vez de "quem aceitar".
        --
        -- Sao duas perguntas diferentes, e o original tem as duas: "quem quer isto" e "onde fica a
        -- forja". A segunda e o que deixa mover um bau de lugar sem reeditar cano nenhum.
        local slot = tonumber(args[5])
        local nome = args[6]

        if slot == nil then
            responder(ctx, "uso: /mod logistica destino <x> <y> <z> <slot> [<nome do satelite>]"
                            .. " -- sem nome, volta a entregar a quem aceitar", true)
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:chassi" then
            responder(ctx, "LOGISTICA nao ha chassi em " .. x .. "," .. y .. "," .. z, true)
            return
        end

        local config = chassi.configuracao(ctx, x, y, z, slot)
        config.satelite = nome
        chassi.configurar(ctx, x, y, z, slot, config)
        ctx.server.schedule_block(x, y, z, chassi.INTERVALO)

        if nome == nil then
            responder(ctx, "LOGISTICA slot " .. slot .. " volta a entregar a quem aceitar")
        else
            -- Confere agora, e nao no primeiro tique: um nome errado ficaria em silencio para
            -- sempre, porque um extrator sem destino simplesmente nao age.
            local nos = rede.varrer(ctx, x, y, z)
            local achado = abastecimento.achar_satelite(ctx, nos, nome)
            responder(ctx, "LOGISTICA slot " .. slot .. " entrega no satelite " .. nome
                           .. (achado == nil and " -- ATENCAO: nenhum satelite com esse nome na rede"
                               or ""),
                      achado == nil)
        end
        return
    end

    if acao == "fabricantes" then
        -- Quem, na rede, sabe fabricar o que -- e quem esta configurado pela metade.
        --
        -- Existe porque a fabricacao decide sozinha: sem uma lista, "a rede nao faz aquilo" e
        -- indistinguivel de "o cano esta la e nao entendi o padrao dele". A resposta separa as duas.
        local nos = rede.varrer(ctx, x, y, z)
        responder(ctx, "LOGISTICA rede com " .. #nos .. " cano(s)")

        local canos, prontos = 0, 0
        for _, no in ipairs(nos) do
            if rede.FABRICADORES[no.bloco] ~= nil then
                canos = canos + 1

                local padrao = chassi.padrao_do_bloco(ctx, no.x, no.y, no.z)
                local saida = chassi.resultado_do_bloco(ctx, no.x, no.y, no.z)
                local onde = "  " .. no.x .. "," .. no.y .. "," .. no.z .. " "
                             .. string.gsub(no.bloco, "^logistica:", "")

                if padrao == nil then
                    responder(ctx, onde .. ": SEM PADRAO -- os nove slots estao vazios", true)
                else
                    -- Quantos itens diferentes o padrao usa, para a linha caber no chat.
                    local ingredientes = {}
                    for _, ingrediente in ipairs(fabricacao.ingredientes_do_padrao(padrao)) do
                        ingredientes[#ingredientes + 1] = ingrediente.count .. "x"
                                .. string.gsub(ingrediente.item, "^minecraft:", "")
                    end

                    if saida == nil then
                        -- O jogo pode conhecer o arranjo mesmo sem resultado declarado.
                        local ok, doJogo = pcall(function()
                            return ctx.server.crafting_result(padrao)
                        end)
                        saida = ok and doJogo or nil
                    end

                    if saida == nil then
                        responder(ctx, onde .. ": padrao de " .. table.concat(ingredientes, "+")
                                       .. " -- SEM RESULTADO; ponha o produto no slot de saida",
                                  true)
                    else
                        prontos = prontos + 1
                        responder(ctx, onde .. ": " .. table.concat(ingredientes, "+")
                                       .. " -> " .. saida.count .. "x"
                                       .. string.gsub(saida.item, "^minecraft:", ""))
                    end
                end
            end
        end

        -- Os modulos fabricantes do chassi contam junto: para quem pergunta, tanto faz de onde a
        -- receita vem.
        local padroes = chassi.padroes_na_rede(ctx, nos)
        if canos == 0 and #padroes == 0 then
            responder(ctx, "LOGISTICA nenhum fabricador nesta rede", true)
        else
            responder(ctx, "LOGISTICA " .. #padroes .. " receita(s) que a rede sabe fazer"
                           .. " (" .. prontos .. " de " .. canos .. " cano(s) prontos)")
        end
        return
    end

    if acao == "resultado" then
        -- Declara o que aquele cano produz, quando o jogo nao sabe dizer.
        --
        -- **E o que abre o sistema para qualquer maquina.** Um forno, um moedor, uma prensa de
        -- outro mod: o loader nao entende nenhum deles, e nao precisa. O padrao diz o que entra, o
        -- resultado diz o que sai, e a rede trata os dois como qualquer outra receita.
        local item = args[5]
        local quantidade = tonumber(args[6]) or 1

        local bloco = ctx.server.get_block(x, y, z)
        if bloco == nil or string.sub(bloco, 1, 20) ~= "logistica:fabricador" then
            responder(ctx, "LOGISTICA nao ha fabricador em " .. x .. "," .. y .. "," .. z, true)
            return
        end
        if item == nil then
            local atual = chassi.resultado_do_bloco(ctx, x, y, z)
            responder(ctx, "uso: /mod logistica resultado <x> <y> <z> <item> [quantidade]"
                            .. " -- hoje: "
                            .. (atual and (atual.count .. " x " .. atual.item) or "nada declarado"),
                      true)
            return
        end

        if not string.find(item, ":") then item = "minecraft:" .. item end
        chassi.declarar_resultado(ctx, x, y, z, item, quantidade)
        responder(ctx, "LOGISTICA este cano passa a produzir " .. quantidade .. " x " .. item)
        return
    end

    if acao == "importar" then
        local ok, mensagem = importar_padrao(ctx, x, y, z)
        responder(ctx, mensagem, not ok)
        return
    end

    if acao == "padrao" then
        -- O padrao de bancada de um slot fabricante, num argumento so.
        --
        -- Nove argumentos separados seriam nove chances de errar a contagem e nenhuma forma de ver
        -- o engano: o formato com barras desenha a bancada na propria linha de comando, e um
        -- tracinho e a celula vazia.
        --
        --   /mod logistica padrao 0 tabua,-,-/tabua,-,-/-,-,-
        local slot = tonumber(args[5])
        local desenho = args[6]

        if slot == nil or desenho == nil then
            responder(ctx, "uso: /mod logistica padrao <x> <y> <z> <slot>"
                            .. " <linha/linha/linha>, celulas separadas por virgula e - para vazia",
                      true)
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:chassi" then
            responder(ctx, "LOGISTICA nao ha chassi em " .. x .. "," .. y .. "," .. z, true)
            return
        end

        local padrao = {}
        for slotDoPadrao = 1, 9 do padrao[slotDoPadrao] = "" end

        local celula = 1
        for linha in string.gmatch(desenho, "[^/]+") do
            for item in string.gmatch(linha, "[^,]+") do
                if celula <= 9 then
                    -- Sem namespace vale minecraft, como em todo comando do jogo.
                    if item ~= "-" then
                        padrao[celula] = string.find(item, ":") and item or ("minecraft:" .. item)
                    end
                    celula = celula + 1
                end
            end
            -- Uma linha curta nao empurra a proxima para cima: a bancada e 3x3, e "tabua/-,tabua"
            -- precisa dizer a mesma coisa que "tabua,-,-/-,tabua,-".
            celula = math.ceil(celula / 3) * 3 + 1
            if celula > 10 then break end
        end

        local ok, saida = pcall(function() return ctx.server.crafting_result(padrao) end)
        if not ok then
            responder(ctx, "LOGISTICA " .. tostring(saida), true)
            return
        end
        if saida == nil then
            responder(ctx, "LOGISTICA esse arranjo nao faz nada", true)
            return
        end

        chassi.configurar(ctx, x, y, z, slot, { padrao = padrao })
        ctx.server.schedule_block(x, y, z, chassi.INTERVALO)
        responder(ctx, "LOGISTICA padrao no slot " .. slot .. " faz "
                       .. saida.count .. " x " .. saida.item)
        return
    end

    if acao == "modulo" then
        local slot = tonumber(args[5])
        local item = args[6]
        local alvo = tonumber(args[7])

        if slot == nil or item == nil then
            responder(ctx, "uso: /mod logistica modulo <x> <y> <z> <slot> <item> [quantidade]", true)
            return
        end
        if ctx.server.get_block(x, y, z) ~= "logistica:chassi" then
            responder(ctx, "LOGISTICA nao ha chassi em " .. x .. "," .. y .. "," .. z, true)
            return
        end

        chassi.configurar(ctx, x, y, z, slot, { item = item, alvo = alvo })

        ctx.server.schedule_block(x, y, z, chassi.INTERVALO)

        ctx.log.info("LOGISTICA modulo slot=" .. slot .. " item=" .. item
                     .. " alvo=" .. tostring(alvo))
        return
    end

    if acao == "fabricar" then
        local item = args[5]
        local quantidade = tonumber(args[6]) or 1
        if item == nil then
            responder(ctx, "uso: /mod logistica fabricar <x> <y> <z> <item> [quantidade]", true)
            return
        end

        local nos = rede.varrer(ctx, x, y, z)
        local destino = { x = x, y = y, z = z, bloco = ctx.server.get_block(x, y, z) }

        -- Planejar antes de mexer em qualquer coisa: um pedido que descobre no meio que falta um
        -- ingrediente ja consumiu os outros, e a base fica com material picado e nada pronto.
        local atendido, motivo, plano = fabricacao.planejar(ctx, nos, item, quantidade)

        if atendido < quantidade then
            ctx.log.warn("LOGISTICA nao da para fazer " .. quantidade .. " " .. item
                         .. ": " .. tostring(motivo))
            return
        end

        ctx.log.info("LOGISTICA plano para " .. quantidade .. " " .. item .. ": "
                     .. #plano.fabricar .. " passo(s)")
        for _, passo in ipairs(plano.fabricar) do
            ctx.log.info("LOGISTICA   fazer " .. (passo.lotes * passo.por_lote) .. " "
                         .. passo.item .. " em " .. passo.lotes .. " lote(s)")
        end

        local pronto, erro = fabricacao.executar(ctx, nos, plano, destino)
        responder(ctx, "LOGISTICA fabricado=" .. pronto .. " motivo=" .. tostring(erro))
        return
    end

    local nos, cortou = rede.varrer(ctx, x, y, z)
    local lista = rede.estoque(ctx, nos)

    if acao == "pedir" then
        local item = args[5]
        if item == nil then
            responder(ctx, "falta o item: /logistica pedir <x> <y> <z> <item>", true)
            return
        end

        local entregue, motivo = viagem.entregar(ctx, nos, { x = x, y = y, z = z },
                                               item, rede.POR_PEDIDO)
        responder(ctx, "LOGISTICA entregue=" .. entregue .. " item=" .. item
                       .. " motivo=" .. tostring(motivo), entregue == 0)
        return
    end

    ctx.log.info("LOGISTICA canos=" .. #nos .. " itens=" .. #lista
                 .. (cortou and " (rede cortada no teto)" or ""))
    for _, entrada in ipairs(lista) do
        responder(ctx, "LOGISTICA  " .. entrada.item .. " x" .. entrada.count)
    end
end)

local function on_loader_ready(ctx)
    responder(ctx, "Logistica pronta: use o Terminal Logistico com um bau encostado nele.")
end

return {
    on_loader_ready = on_loader_ready,
}
