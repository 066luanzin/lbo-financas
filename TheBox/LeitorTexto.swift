import Foundation
import SwiftData

/// Lê o texto de um e-mail ou SMS do banco ("Pix enviado de R$ 50,00 para FULANO") e descobre
/// valor, se é gasto ou receita e o nome de quem pagou/recebeu.
@MainActor
enum LeitorTexto {
    struct Resultado {
        var valor: Double
        var tipo: TipoTransacao
        var nome: String
        var texto: String
    }

    private static let saida = ["pix enviado", "enviou", "voce enviou", "transferencia enviada", "transferiu", "pagamento",
                                "pagou", "compra", "debitado", "debito de", "saque", "boleto pago", "pix realizado",
                                "transferencia realizada", "pix feito", "foi enviado", "enviado"]
    private static let entrada = ["pix recebido", "recebeu", "voce recebeu", "recebimento", "transferencia recebida",
                                  "deposito", "creditado", "credito em conta", "salario", "rendimento", "foi recebido", "recebido"]

    /// Lê o texto e registra o gasto/receita. Sempre avisa o que aconteceu.
    static func registrar(texto: String, ctx: ModelContext, foto: Data? = nil, banco: String? = nil) throws {
        UserDefaults.standard.set(String(texto.prefix(3000)), forKey: "ultimoTextoLido")
        UserDefaults.standard.set(Date.now, forKey: "ultimoTextoData")
        guard let r = ler(texto) else {
            Notificacoes.agora("Não achei o valor",
                               texto.isEmpty ? "O comprovante chegou vazio. Tente compartilhar como imagem."
                                             : "Veja o texto recebido em Config → Automação → Pix e mande pro suporte.")
            return
        }
        let quando = achaData(texto) ?? .now
        if duplicado(r, quando: quando, ctx: ctx) {
            Notificacoes.agora("Já estava registrado", "\(r.valor.moeda) desse horário já está no app.")
            return
        }
        let cart = carteira(r, ctx: ctx, banco: banco)
        if ehPropriaConta(r.nome) {
            // Pix entre contas suas não é gasto nem receita
            let tr = Transacao(tipo: .transferencia, valor: r.valor, categoria: Transacao.outraConta, carteira: cart,
                               descricao: r.nome, data: quando, entrada: r.tipo == .receita)
            tr.foto = foto
            ctx.insert(tr)
            try ctx.save()
            Notificacoes.agora("\(r.valor.moeda) transferido", "Entre contas suas: não conta como gasto.")
            Notificacoes.reagendar(ctx)
            return
        }
        let cat = categoria(r, ctx: ctx)
        let nova = Transacao(tipo: r.tipo, valor: r.valor, categoria: cat, carteira: cart, descricao: r.nome, data: quando)
        nova.foto = foto
        ctx.insert(nova)
        try ctx.save()
        Notificacoes.registrado(valor: r.valor, titulo: r.nome.isEmpty ? r.tipo.nome : r.nome, categoria: cat)
        if r.tipo == .gasto {
            Notificacoes.verificarLimite(categoria: cat, valor: r.valor, data: .now, ctx: ctx)
        }
        Notificacoes.reagendar(ctx)
    }

    /// O nome é o seu (Pix pra outra conta sua)? Ignora quando começa com número (CNPJ, ex.: seu MEI pagando salário)
    static func ehPropriaConta(_ nome: String) -> Bool {
        let meu = Categorizador.normalizar(UserDefaults.standard.string(forKey: "nomeUsuario") ?? "")
            .split(separator: " ").map(String.init)
        guard let primeiro = meu.first, meu.count >= 2, let ultimo = meu.last else { return false }
        let n = Categorizador.normalizar(nome)
        guard let c = n.first, !c.isNumber else { return false }
        return n.contains(primeiro) && n.contains(ultimo)
    }

    static func ler(_ bruto: String) -> Resultado? {
        let texto = bruto.replacingOccurrences(of: "\u{00a0}", with: " ")
        guard let valor = achaValor(texto), valor > 0 else { return nil }
        let t = Categorizador.normalizar(texto)
        let ehSaida = saida.contains { t.contains($0) }
        let ehEntrada = entrada.contains { t.contains($0) }
        let tipo: TipoTransacao = (ehEntrada && !ehSaida) ? .receita : .gasto
        return Resultado(valor: valor, tipo: tipo, nome: achaNome(texto, tipo: tipo), texto: t)
    }

    /// Data e hora que vêm no texto ("29/09/2026 às 18:03", "29 SET 2026 - 18:03:21", "13 de setembro de 2026, às 19:52").
    /// Só aceita se for dos últimos 30 dias; senão, fica com a hora de agora.
    static func achaData(_ s: String) -> Date? {
        let t = Categorizador.normalizar(s)
        let cal = Calendar.current
        let agora = Date.now
        var dia: Int?
        var mes: Int?
        var ano = cal.component(.year, from: agora)
        func grupo(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: t) else { return nil }
            return String(t[r])
        }
        let meses = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) {
            dia = grupo(m, 1).flatMap { Int($0) }
            mes = grupo(m, 2).flatMap { Int($0) }
            if let a = grupo(m, 3).flatMap({ Int($0) }) { ano = a < 100 ? 2000 + a : a }
        } else if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})\s*(?:de\s+)?(jan|fev|mar|abr|mai|jun|jul|ago|set|out|nov|dez)[a-z]*\.?\s*(?:de\s+)?(\d{4})?"#),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) {
            dia = grupo(m, 1).flatMap { Int($0) }
            mes = grupo(m, 2).flatMap { meses.firstIndex(of: $0) }.map { $0 + 1 }
            if let a = grupo(m, 3).flatMap({ Int($0) }) { ano = a }
        }
        var hora = cal.component(.hour, from: agora)
        var minuto = cal.component(.minute, from: agora)
        var achouHora = false
        if let re = try? NSRegularExpression(pattern: #"\b([01]?\d|2[0-3])[:h](\d{2})\b"#),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let h = grupo(m, 1).flatMap({ Int($0) }), let mi = grupo(m, 2).flatMap({ Int($0) }) {
            hora = h
            minuto = mi
            achouHora = true
        }
        guard dia != nil || achouHora else { return nil }
        var c = cal.dateComponents([.year, .month, .day], from: agora)
        if let dia, let mes { c.day = dia; c.month = mes; c.year = ano }
        c.hour = hora
        c.minute = minuto
        guard let d = cal.date(from: c), d <= agora.addingTimeInterval(60),
              d >= agora.addingTimeInterval(-30 * 24 * 3600) else { return nil }
        return d
    }

    /// Primeiro "R$ 1.234,56" do texto
    static func achaValor(_ s: String) -> Double? {
        let padrao = #"R\$\s*-?\s*(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:,\d{1,2})?)"#
        guard let re = try? NSRegularExpression(pattern: padrao),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let numero = String(s[r]).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        return Double(numero)
    }

    /// Nome depois de "para"/"em" (gasto) ou "de"/"por" (receita), sem pegar o próprio valor
    static func achaNome(_ s: String, tipo: TipoTransacao) -> String {
        // Comprovante (ex.: Nubank): "Destino ... Nome\nFULANO" (ou "Origem" quando é receita)
        if let r = s.range(of: tipo == .gasto ? "Destino" : "Origem", options: .caseInsensitive) {
            let linhas = s[r.upperBound...].split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let i = linhas.firstIndex(where: { $0.lowercased() == "nome" }), i + 1 < linhas.count {
                return linhas[i + 1]
            }
            if let l = linhas.first(where: { $0.lowercased().hasPrefix("nome ") }) {
                return String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        let fimNome = #"(?=\s*(?:[\.,;:\n\(]|\bno valor\b|\bvia\b|\bcom\b|\bem \d|\bno dia\b|\bàs\b|\bas \d|\bpara\b|\bno cart|$))"#
        let preposicoes = tipo == .gasto ? ["para", "pra", "em", "no", "na"] : ["de", "por"]
        for p in preposicoes {
            let padrao = #"(?i)\b"# + p + #"\s+(?!R\$)(?!\d)([^\n]{2,50}?)"# + fimNome
            guard let re = try? NSRegularExpression(pattern: padrao),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { continue }
            var nome = String(s[r]).trimmingCharacters(in: .whitespaces)
            for lixo in [" com sucesso", " foi", " realizado", " realizada"] {
                if let x = nome.range(of: lixo, options: .caseInsensitive) { nome = String(nome[..<x.lowerBound]) }
            }
            let n = Categorizador.normalizar(nome)
            let ignorar = ["sua conta", "seu cartao", "o cartao", "a conta", "cartao", "conta", "voce", "pix", "transferencia"]
            if nome.count >= 2 && !ignorar.contains(where: { n.hasPrefix($0) }) { return nome }
        }
        return ""
    }

    /// Evita registrar duas vezes (ex.: e-mail e SMS do mesmo Pix, ou a compra que já veio pela maquininha)
    /// Mesmo valor e tipo: registrado nos últimos 30 min, ou com o mesmo horário do comprovante (±2 min)
    static func duplicado(_ r: Resultado, quando: Date, ctx: ModelContext) -> Bool {
        let limite = min(Date.now.addingTimeInterval(-30 * 60), quando.addingTimeInterval(-120))
        var busca = FetchDescriptor<Transacao>(predicate: #Predicate { $0.data > limite })
        busca.fetchLimit = 200
        let recentes = (try? ctx.fetch(busca)) ?? []
        let meiaHora = Date.now.addingTimeInterval(-30 * 60)
        return recentes.contains {
            $0.tipoRaw == r.tipo.rawValue && abs($0.valor - r.valor) < 0.01
                && ($0.data > meiaHora || abs($0.data.timeIntervalSince(quando)) < 120)
        }
    }

    static func categoria(_ r: Resultado, ctx: ModelContext) -> String {
        if r.tipo == .gasto { return Categorizador.categoria(para: r.nome, ctx: ctx) }
        let cats = ((try? ctx.fetch(FetchDescriptor<Categoria>(sortBy: [SortDescriptor(\.ordem)]))) ?? [])
            .filter { $0.tipoRaw == TipoTransacao.receita.rawValue }.map(\.nome)
        if r.texto.contains("salario"), let s = cats.first(where: { Categorizador.normalizar($0).contains("salario") }) { return s }
        if r.texto.contains("rendimento"), let s = cats.first(where: { Categorizador.normalizar($0).contains("invest") }) { return s }
        return cats.first(where: { $0 == "Outros" }) ?? cats.first ?? "Outros"
    }

    static func carteira(_ r: Resultado, ctx: ModelContext, banco: String? = nil) -> String {
        let lista = (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        // banco escolhido na automação
        if let banco, let c = lista.first(where: { Categorizador.normalizar($0.nome) == Categorizador.normalizar(banco) }) {
            return c.nome
        }
        // nome do banco no texto (o que aparece primeiro costuma ser quem mandou o aviso)
        let contas = lista.filter { $0.tipo != .credito }
        let achados = contas.compactMap { c -> (Carteira, String.Index)? in
            let n = Categorizador.normalizar(c.nome)
            guard n.count >= 4, let r = r.texto.range(of: n) else { return nil }
            return (c, r.lowerBound)
        }
        if let primeiro = achados.min(by: { $0.1 < $1.1 }) { return primeiro.0.nome }
        if r.texto.contains("pix"), let c = lista.first(where: { $0.tipo == .pix }) { return c.nome }
        if r.texto.contains("debito"), let c = lista.first(where: { $0.tipo == .debito }) { return c.nome }
        if r.texto.contains("credito") || r.texto.contains("cartao"),
           let c = lista.first(where: { $0.tipo == .credito }) { return c.nome }
        return lista.first(where: { $0.tipo == .pix })?.nome ?? contas.first?.nome ?? lista.first?.nome ?? ""
    }
}
