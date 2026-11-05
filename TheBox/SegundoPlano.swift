import Foundation
import BackgroundTasks
import SwiftData

/// O iPhone acorda o app de vez em quando (ele decide quando) pra puxar o que foi mudado no site
@MainActor
enum SegundoPlano {
    static let id = "com.lbofinancas.app.pedidos"

    /// Pede pro iPhone acordar o app daqui a uns 30 minutos (ou quando ele achar melhor)
    static func agendar() {
        let pedido = BGAppRefreshTaskRequest(identifier: id)
        pedido.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(pedido)
    }

    static func rodar() async {
        agendar()
        guard let container = Store.atual else { return }
        let ctx = container.mainContext
        Recorrencias.gerar(ctx)
        await Pedidos.aplicar(ctx)
    }
}
