import SwiftUI
import SwiftData

/// Trocar todas as contas por uma lista colada (uma conta por linha)
///   Fatura Nubank | 202,97 | 03/11/2026   → conta única que vence nesse dia
///   iCloud | 19,90 | dia 24 | fixa         → conta fixa todo mês
enum ListaContas {
    struct Item {
        let nome: String
        let valor: Double
        let dia: Int
        /// Mês (ver Mes.indice) da conta única; nil = fixa todo mês
        let mes: Int?
    }

    static func ler(_ texto: String) -> [Item] {
        texto.components(separatedBy: .newlines).compactMap { linha in
            let l = linha.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
            let partes = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard partes.count >= 3, !partes[0].isEmpty, let valor = lerValor(partes[1]), valor > 0 else { return nil }
            let data = partes[2].split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if data.count == 3, (1...31).contains(data[0]), (1...12).contains(data[1]) {
                return Item(nome: partes[0], valor: valor, dia: data[0], mes: data[2] * 12 + data[1] - 1)
            }
            let dia = Int(partes[2].filter(\.isNumber)) ?? 10
            return Item(nome: partes[0], valor: valor, dia: min(max(dia, 1), 31), mes: nil)
        }
    }

    /// As contas antigas param depois deste mês (o passado e este mês ficam como estão);
    /// as da lista começam no mês que vem. Desliga a fatura automática dos cartões pra não contar duas vezes.
    @MainActor
    static func substituir(_ itens: [Item], ctx: ModelContext) {
        let hoje = Mes.indice()
        let antigas = (try? ctx.fetch(FetchDescriptor<Conta>())) ?? []
        for c in antigas {
            if c.inicio > hoje { ctx.delete(c) } else if c.fim == 0 || c.fim > hoje { c.fim = hoje }
        }
        for cartao in (try? ctx.fetch(FetchDescriptor<Carteira>())) ?? [] where cartao.tipo == .credito {
            cartao.diaFechamento = 0
        }
        for item in itens {
            let fixa = item.mes == nil
            let categoria = Categorizador.categoria(para: item.nome, ctx: ctx)
            ctx.insert(Conta(nome: item.nome, valor: item.valor, dia: item.dia, venceMesSeguinte: false,
                             categoria: categoria, repetir: fixa, parcelaAtual: 0, totalParcelas: 0,
                             inicio: item.mes ?? hoje + 1))
        }
        try? ctx.save()
        Notificacoes.reagendar(ctx)
    }
}

struct SubstituirContasSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @State private var texto = ""
    @State private var confirmar = false

    var body: some View {
        let itens = ListaContas.ler(texto)
        let fixas = itens.filter { $0.mes == nil }
        let unicas = itens.filter { $0.mes != nil }
        let hoje = Mes.indice()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cole a lista com uma conta por linha. As contas de hoje param depois de \(Mes.nome(hoje).lowercased()) e as da lista entram a partir de \(Mes.nome(hoje + 1).lowercased()).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        texto = UIPasteboard.general.string ?? ""
                    } label: {
                        Label("Colar", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(EstiloContorno())
                    TextEditor(text: $texto)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Color.cartao2.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if !itens.isEmpty {
                        Text("\(unicas.count) parcelas com data · \(fixas.count) contas fixas")
                            .font(.system(size: 14, weight: .semibold))
                        ForEach(Array(itens.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.nome).font(.system(size: 14)).lineLimit(1)
                                Spacer()
                                Text(item.mes.map { "\(item.dia)/\(mesAno($0))" } ?? "todo dia \(item.dia)")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Text(item.valor.moeda).font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                    Button("Substituir minhas contas") { confirmar = true }
                        .buttonStyle(EstiloPrincipal(ativo: !itens.isEmpty))
                        .disabled(itens.isEmpty)
                }
                .padding(20)
            }
            .background(Color.cartao)
            .navigationTitle("Substituir contas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .confirmationDialog("Substituir as contas?", isPresented: $confirmar, titleVisibility: .visible) {
                Button("Substituir", role: .destructive) {
                    ListaContas.substituir(itens, ctx: ctx)
                    Notificacoes.agora("Contas atualizadas", "\(itens.count) contas cadastradas a partir de \(Mes.nome(hoje + 1).lowercased()).")
                    dismiss()
                }
            } message: {
                Text("As contas que você tem hoje continuam em \(Mes.nome(hoje).lowercased()) e nos meses passados, e somem dos próximos meses. A fatura automática do cartão é desligada pra não contar a fatura duas vezes.")
            }
        }
    }
}
