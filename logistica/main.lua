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
local fabricador = mod.import("lib/fabricador.lua")
local chassi = mod.import("lib/chassi.lua")
local viagem = mod.import("lib/viagem.lua")

mod.screen("terminal", terminal.evento)
mod.screen("fabricador", fabricador.evento)

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
