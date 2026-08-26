-- O chassi: um cano cujo comportamento vem dos modulos que estao dentro dele.
--
-- No original ele e o `chassis`, e e a peca que muda como se joga. Sem ele a rede so faz o que se
-- pede a mao; com ele, cada bau da base ganha um papel -- este recebe ferro, aquele exporta o que
-- produz, aquele outro se mantem abastecido -- e a rede passa a funcionar sozinha.
--
-- **O comportamento e um item dentro do bloco, e nao uma configuracao.** E assim que o original
-- faz, e a razao e boa: trocar o papel de um bau e trocar um item de lugar, sem comando nenhum, e o
-- que esta ali se ve pela tela do bloco. Um chassi vazio nao faz nada e nao custa nada.
--
-- Os tres modulos daqui sao os que sustentam o resto:
--
--   extrator      tira do bau encostado e manda para quem na rede aceitar
--   deposito      declara que este bau recebe um item; a rede entrega aqui
--   abastecedor   mantem o bau com uma quantidade, como o cano abastecedor
--
-- `quick_sort`, `terminus` e `crafter` do original sao variacoes destes.

local rede = mod.import("lib/rede.lua")
local viagem = mod.import("lib/viagem.lua")

-- De quanto em quanto um chassi age.
--
-- Vinte tiques, um segundo. Mais rapido que o abastecedor porque um extrator parado e material
-- parado, e mais lento que o tique do cano porque cada volta le o inventario dos modulos.
local INTERVALO = 20

-- Quanto um extrator manda por vez.
--
-- Uma pilha por volta. Mandar tudo de uma vez encheria a rede com cargas de um bau so, e o resto da
-- base ficaria esperando -- o mesmo motivo de o provedor do original mandar 16.
local POR_VEZ = 16

local MODULOS = {
    ["logistica:modulo_extrator"] = "extrator",
    ["logistica:modulo_deposito"] = "deposito",
    ["logistica:modulo_abastecedor"] = "abastecedor",
    ["logistica:modulo_separador"] = "separador",
    ["logistica:modulo_descarte"] = "descarte",
    ["logistica:modulo_fabricante"] = "fabricante",
}

--- Os modulos que estao dentro daquele chassi, por slot.
--
-- Le o inventario do proprio bloco. O que nao e modulo e ignorado em silencio: o inventario e
-- aberto por quem joga, e recusar um item ali seria recusar um engano sem consequencia.
local function modulos_em(ctx, x, y, z)
    local encontrados = {}

    for _, entrada in ipairs(ctx.server.container_at(x, y, z)) do
        local tipo = MODULOS[entrada.item]
        if tipo ~= nil then
            encontrados[#encontrados + 1] = { tipo = tipo, slot = entrada.slot }
        end
    end
    return encontrados
end

--- A configuracao de um slot de modulo, guardada na posicao do chassi.
--
-- Por slot, e nao por chassi: dois depositos no mesmo bloco recebem itens diferentes, e e disso que
-- vem a utilidade de ter mais de um slot.
local function configuracao(ctx, x, y, z, slot)
    local dados = ctx.server.get_block_data(x, y, z)
    local todos = dados.modulos or {}
    return todos[tostring(slot)] or {}, dados
end

local function configurar(ctx, x, y, z, slot, config)
    local dados = ctx.server.get_block_data(x, y, z)
    dados.modulos = dados.modulos or {}
    dados.modulos[tostring(slot)] = config
    ctx.server.set_block_data(x, y, z, dados)
end

-- ------------------------------------------------------------------ o que a rede pergunta

--- Onde na rede um item e aceito.
--
-- Devolve a posicao do chassi que o recebe, ou nil. E a pergunta que o original chama de
-- `sinksItem`, e e o que faz um item extraido saber para onde ir sem ninguem dizer.
--
-- O primeiro que aceita ganha, e a varredura devolve os canos em ordem de distancia: o deposito
-- mais perto atende. Prioridade explicita, como a do original, seria o passo seguinte.
local function quem_aceita(ctx, nos, item)
    local descarte = nil

    for _, no in ipairs(nos) do
        if no.bloco == "logistica:chassi" then
            for _, modulo in ipairs(modulos_em(ctx, no.x, no.y, no.z)) do
                if modulo.tipo == "deposito" then
                    local config = configuracao(ctx, no.x, no.y, no.z, modulo.slot)
                    if config.item == item then return no end

                elseif modulo.tipo == "descarte" and descarte == nil then
                    -- Guarda e continua procurando. **O descarte e o ultimo destino, nunca o
                    -- primeiro**: devolve-lo assim que aparece faria a rede destruir o que um
                    -- deposito mais adiante aceitaria -- e o defeito seria silencioso, porque item
                    -- destruido nao deixa rastro.
                    descarte = no
                end
            end
        end
    end
    return descarte
end

--- Se aquele chassi destroi o que chega, em vez de guardar.
--
-- Perguntado na chegada da carga, e nao na saida: entre o despacho e a entrega alguem pode ter
-- tirado o modulo, e destruir por causa de uma decisao velha e a pior forma de errar aqui.
local function e_descarte(ctx, x, y, z)
    if ctx.server.get_block(x, y, z) ~= "logistica:chassi" then return false end

    for _, modulo in ipairs(modulos_em(ctx, x, y, z)) do
        if modulo.tipo == "descarte" then return true end
    end
    return false
end

--- O que aquele padrao produz, guardado no proprio bloco.
--
-- `crafting_result` pergunta ao livro de receitas do jogo, e a busca percorre as receitas do tipo
-- ate casar -- num modpack sao milhares. A rede pergunta por cano a cada planejamento, e isso
-- sozinho aproxima o callback dos 20 ms.
--
-- O padrao so muda quando alguem mexe nos slots, entao a resposta vale ate la. A chave e o proprio
-- padrao concatenado: comparar o texto e barato, e um padrao diferente invalida sozinho.
local function resultado_calculado(ctx, x, y, z, padrao)
    local chave = table.concat(padrao, "|")
    local dados = ctx.server.get_block_data(x, y, z)
    local guardado = dados.saida

    if guardado ~= nil and guardado.chave == chave then
        -- `false` guardado significa "o jogo nao conhece", e vale tanto quanto uma resposta boa:
        -- descobrir isso custa a mesma varredura.
        if guardado.item == nil then return nil end
        return { item = guardado.item, count = guardado.count }
    end

    local ok, saida = pcall(function() return ctx.server.crafting_result(padrao) end)
    if not ok then saida = nil end

    dados.saida = saida ~= nil
            and { chave = chave, item = saida.item, count = saida.count }
            or { chave = chave }
    ctx.server.set_block_data(x, y, z, dados)

    return saida
end

--- A maquina acoplada a um cano: o primeiro inventario vizinho que nao e cano.
--
-- E onde um resultado declarado tem que ser produzido. Devolve nil quando nao ha nenhuma, e ai o
-- padrao declarado simplesmente nao entra na lista do que a rede sabe fazer.
local function maquina_de(ctx, no)
    local achados = rede.inventarios_em(ctx, no)
    return achados[1]
end

--- Os padroes de bancada que a rede sabe montar, com o que cada um produz.
--
-- E o que o modulo fabricante acrescenta: sem ele a arvore de pedido so conhece as receitas do
-- jogo, e escolhe sempre a primeira. Com ele, quem monta a base decide **qual** receita a rede usa
-- para cada item -- que e a razao de o modulo existir no original.
--- O que um cano fabricador declara produzir, lido da fileira de baixo.
--
-- **E o que torna o sistema generico.** Sem resultado declarado, a unica forma de saber o que um
-- arranjo faz e perguntar ao livro de receitas do jogo -- e ai a rede so sabe fabricar o que a
-- bancada faz. Com ele, o mesmo cano serve a qualquer maquina acoplada: forno, moedor, prensa de
-- outro mod. O padrao vira "o que entra", o resultado vira "o que sai", e o loader nao precisa
-- entender a maquina do meio.
--
-- O primeiro slot da fileira e o produto; os seguintes sao subproduto -- o balde que volta junto
-- da sopa. Devolve nil quando ninguem declarou nada, e ai quem responde e o jogo.
local function resultado_do_bloco(ctx, x, y, z)
    -- No slot 9, que a janela declarada desenha ao lado da grade -- onde a bancada do jogo poe o
    -- resultado. Ele e fantasma como os outros: e uma declaracao, e nao um item guardado.
    for _, entrada in ipairs(ctx.server.container_at(x, y, z)) do
        if entrada.slot == 9 then
            return { item = entrada.item, count = entrada.count }
        end
    end
    return nil
end

--- Declara o que aquele cano produz.
local function declarar_resultado(ctx, x, y, z, item, quantidade)
    ctx.server.set_slot(x, y, z, 9, item, math.max(1, quantidade or 1))
end

--- O padrao guardado nos nove slots de um bloco.
--
-- Le o inventario do proprio bloco, e nao uma tabela do mod: assim o jogador monta a receita
-- arrastando item com o mouse, na janela do jogo, com o inventario dele embaixo. Uma tela desenhada
-- a mao nao tem slot, e sem slot nao ha como montar um padrao de varios itens sem inventar gesto.
--
-- Os itens ficam ali como desenho: nada e consumido, e `allow_extract` falso impede a propria rede
-- de esvaziar a receita sem ninguem perceber.
local function padrao_do_bloco(ctx, x, y, z)
    local padrao = {}
    for slot = 1, 9 do padrao[slot] = "" end

    local vazio = true
    for _, entrada in ipairs(ctx.server.container_at(x, y, z)) do
        if entrada.slot >= 0 and entrada.slot <= 8 then
            padrao[entrada.slot + 1] = entrada.item
            vazio = false
        end
    end
    if vazio then return nil end
    return padrao
end

local function padroes_na_rede(ctx, nos)
    local achados = {}

    for _, no in ipairs(nos) do
        -- O cano fabricador oferece o proprio padrao. E o que o original faz: a rede pergunta
        -- "quem sabe fazer isto?" e o cano responde com o que esta nos slots dele.
        if rede.FABRICADORES[no.bloco] ~= nil then
            local padrao = padrao_do_bloco(ctx, no.x, no.y, no.z)
            if padrao ~= nil then
                -- **O resultado declarado vence o livro de receitas.** Quem escreveu "isto sai
                -- daqui" sabe da maquina que o loader nao conhece; perguntar ao jogo por cima disso
                -- responderia "esse arranjo nao faz nada" e o cano ficaria mudo na rede.
                local saida = resultado_do_bloco(ctx, no.x, no.y, no.z)
                local declarado = saida ~= nil

                if saida == nil then
                    saida = resultado_calculado(ctx, no.x, no.y, no.z, padrao)
                end

                -- **Um resultado declarado sem maquina nao entra na lista.**
                --
                -- A lista responde "o que esta rede sabe fazer", e uma declaracao sem maquina nao e
                -- uma resposta: e uma afirmacao sobre uma prensa que nao existe. Filtrar aqui, e
                -- nao no planejamento, e o que faz o terminal e o `/mod logistica fabricantes`
                -- contarem a mesma verdade -- eles leem esta lista.
                local maquina = declarado and maquina_de(ctx, no) or nil
                if declarado and maquina == nil then saida = nil end

                if saida ~= nil then
                    -- **De onde veio o resultado muda quem faz o trabalho.**
                    --
                    -- Uma receita que o jogo conhece, o cano faz sozinho: e o mesmo que um jogador
                    -- montando na bancada, e nada aparece que ele nao pudesse fazer a mao.
                    --
                    -- Um resultado declarado e uma afirmacao sobre uma MAQUINA -- "esta prensa faz
                    -- cascalho de pedra". Sem a maquina, aceitar a afirmacao seria criar item do
                    -- nada segundo uma regra que o proprio jogador escreveu: duplicacao livre num
                    -- servidor com outras pessoas.
                    achados[#achados + 1] = {
                        no = no,
                        padrao = padrao,
                        saida = saida,
                        declarado = declarado,
                        maquina = maquina,
                    }
                end
            end
        end

        if no.bloco == "logistica:chassi" then
            for _, modulo in ipairs(modulos_em(ctx, no.x, no.y, no.z)) do
                if modulo.tipo == "fabricante" then
                    local config = configuracao(ctx, no.x, no.y, no.z, modulo.slot)
                    local padrao = config.padrao

                    if padrao ~= nil then
                        local ok, saida = pcall(function()
                            return ctx.server.crafting_result(padrao)
                        end)
                        if ok and saida ~= nil then
                            achados[#achados + 1] = { no = no, padrao = padrao, saida = saida }
                        end
                    end
                end
            end
        end
    end
    return achados
end

-- ------------------------------------------------------------------ o tique

--- Um extrator: tira do bau encostado e manda para quem aceitar.
local function agir_extrator(ctx, nos, no, config)
    if config.item == nil then return 0 end

    local destino
    if config.satelite ~= nil then
        -- Endereco nomeado: "mande para a forja", sem saber onde a forja fica. E a metade que
        -- faltava do satelite -- ele guardava o nome e ninguem roteava por ele.
        --
        -- Mover a forja de lugar nao mexe em cano nenhum, e trocar qual bau e a forja e renomear um
        -- satelite. Com `quem_aceita` isso nao da: o destino ali e "quem declarou querer este
        -- item", que e uma pergunta sobre o item e nao sobre o lugar.
        --
        -- O `import` fica dentro da funcao porque abastecimento importa viagem, que importa este
        -- modulo: no topo isso fecharia um ciclo.
        destino = mod.import("lib/abastecimento.lua").achar_satelite(ctx, nos, config.satelite)

        -- Satelite que nao existe mais nao vira entrega em outro lugar. Cair no `quem_aceita`
        -- mandaria a producao da forja para um bau qualquer, e ninguem repararia ate faltar.
        if destino == nil then return 0 end
    else
        destino = quem_aceita(ctx, nos, config.item)
    end
    if destino == nil then return 0 end

    -- Nao manda para si mesmo: o item sairia e voltaria ao mesmo bau para sempre, e a rede
    -- pareceria trabalhar sem nada acontecer.
    if destino.x == no.x and destino.y == no.y and destino.z == no.z then return 0 end

    local caminho = rede.rota(ctx, no, destino)
    if caminho == nil then return 0 end

    local enviado = 0
    for _, fonte in ipairs(rede.inventarios_em(ctx, no)) do
        if enviado >= POR_VEZ then break end

        local tirado = ctx.server.extract_from(fonte.x, fonte.y, fonte.z,
                                               config.item, POR_VEZ - enviado)
        if tirado > 0 then
            local carga = { item = config.item, count = tirado, rota = caminho, passo = 1 }
            if viagem.por_carga(ctx, no.x, no.y, no.z, carga) then
                enviado = enviado + tirado
            else
                -- A linha esta cheia: devolve, senao o item deixa de existir.
                ctx.server.insert_into(fonte.x, fonte.y, fonte.z, config.item, tirado)
            end
        end
    end
    return enviado
end

--- Um separador: manda embora tudo que achar, cada item para quem o aceitar.
--
-- A diferenca para o extrator e que ele nao tem item configurado: le o que esta no bau e procura
-- destino para cada coisa. E o que transforma um bau de despejo em entrada da base -- joga tudo ali
-- e a rede distribui.
--
-- O teto por volta e o mesmo do extrator, e vale para o **conjunto**: sem isso um bau cheio de
-- coisas diferentes faria uma varredura de rota por item, e o orcamento de 20 ms nao tem essa
-- folga.
local function agir_separador(ctx, nos, no)
    local enviado = 0

    for _, fonte in ipairs(rede.inventarios_em(ctx, no)) do
        if enviado >= POR_VEZ then break end

        -- O conteudo e lido uma vez e percorrido: reler a cada item pagaria a leitura do bau
        -- inteiro por pilha movida.
        for _, entrada in ipairs(ctx.server.container_at(fonte.x, fonte.y, fonte.z)) do
            if enviado >= POR_VEZ then break end

            local destino = quem_aceita(ctx, nos, entrada.item)
            if destino ~= nil
               and not (destino.x == no.x and destino.y == no.y and destino.z == no.z) then

                local caminho = rede.rota(ctx, no, destino)
                if caminho ~= nil then
                    local quanto = math.min(entrada.count, POR_VEZ - enviado)
                    local tirado = ctx.server.extract_from(fonte.x, fonte.y, fonte.z,
                                                           entrada.item, quanto)
                    if tirado > 0 then
                        local carga = { item = entrada.item, count = tirado,
                                        rota = caminho, passo = 1 }
                        if viagem.por_carga(ctx, no.x, no.y, no.z, carga) then
                            enviado = enviado + tirado
                        else
                            -- A linha esta cheia: devolve, senao o item deixa de existir.
                            ctx.server.insert_into(fonte.x, fonte.y, fonte.z,
                                                   entrada.item, tirado)
                        end
                    end
                end
            end
        end
    end
    return enviado
end

--- Um abastecedor de chassi: pede a rede o que falta para o bau chegar ao alvo.
local function agir_abastecedor(ctx, nos, no, config)
    if config.item == nil then return 0 end

    local alvo = tonumber(config.alvo) or 0
    if alvo <= 0 then return 0 end

    local tem = 0
    for _, destino in ipairs(rede.inventarios_em(ctx, no)) do
        for _, entrada in ipairs(ctx.server.container_at(destino.x, destino.y, destino.z)) do
            if entrada.item == config.item then tem = tem + entrada.count end
        end
    end

    local falta = alvo - tem
    if falta <= 0 then return 0 end

    return viagem.entregar(ctx, nos, no, config.item, falta)
end

--- O tique de um chassi: cada modulo age uma vez.
--
-- Reagenda sempre, porque um chassi existe para continuar agindo -- como o abastecedor, e ao
-- contrario do cano comum, que para quando esvazia.
local function passo(ctx, x, y, z)
    local no = { x = x, y = y, z = z, bloco = "logistica:chassi" }
    local modulos = modulos_em(ctx, x, y, z)

    if #modulos > 0 then
        -- A rede e varrida uma vez por tique, e nao uma vez por modulo: tres modulos no mesmo
        -- chassi fariam tres varreduras identicas, e o orcamento de 20 ms nao tem essa folga.
        local nos = rede.varrer(ctx, x, y, z)

        for _, modulo in ipairs(modulos) do
            local config = configuracao(ctx, x, y, z, modulo.slot)

            if modulo.tipo == "extrator" then
                agir_extrator(ctx, nos, no, config)
            elseif modulo.tipo == "separador" then
                agir_separador(ctx, nos, no)
            elseif modulo.tipo == "abastecedor" then
                agir_abastecedor(ctx, nos, no, config)
            end
            -- Deposito, descarte e fabricante nao agem: os tres respondem quando a rede pergunta --
            -- quem aceita este item, quem destroi o que sobra, quem sabe fazer aquilo.
        end
    end

    ctx.server.schedule_block(x, y, z, INTERVALO)
end

return {
    INTERVALO = INTERVALO,
    POR_VEZ = POR_VEZ,
    MODULOS = MODULOS,
    modulos_em = modulos_em,
    configuracao = configuracao,
    configurar = configurar,
    quem_aceita = quem_aceita,
    padrao_do_bloco = padrao_do_bloco,
    maquina_de = maquina_de,
    resultado_do_bloco = resultado_do_bloco,
    declarar_resultado = declarar_resultado,
    e_descarte = e_descarte,
    padroes_na_rede = padroes_na_rede,
    passo = passo,
}
