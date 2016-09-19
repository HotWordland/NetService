import Foundation
import DNS

// TODO: track TTL of records
public class NetServiceBrowser: Listener {
    var client: Client
    var services = [String]()

    // MARK: Creating Network Service Browsers

    public init() {
        client = try! Client.shared()
        client.listeners.append(self)
    }

    deinit {
        if let index = client.listeners.index(where: { $0 === self }) {
            client.listeners.remove(at: index)
        }
    }

    // MARK: Configuring Network Service Browsers

    public var delegate: NetServiceBrowserDelegate?

    // MARK: Using Network Service Browsers

    var currentSearch: (type: String, domain: String)?

    public func searchForServices(ofType type: String, inDomain domain: String) {
        assert(domain == "local.", "only local. domain is supported")
        assert(type.hasSuffix("."), "type label(s) should end with a period")

        currentSearch = (type, domain)
        let query = Message(header: Header(response: false), questions: [Question(name: "\(type).\(domain)", type: .pointer)])
        client.multicast(message: query)
    }

    func received(message: Message) {
        guard let (type, domain) = currentSearch else {
            return
        }

        let newPointers = message.answers
            .flatMap { $0 as? PointerRecord }
            .filter { !self.services.contains($0.destination) }
            .filter { $0.name == "\(type)\(domain)" }

        for pointer in newPointers {
            let service = NetService(domain: domain, type: type, name: pointer.destination.replacingOccurrences(of: ".\(type)\(domain)", with: ""))
            guard let serviceRecord = message.additional.flatMap({ $0 as? ServiceRecord }).first(where: { $0.name == pointer.destination }) else {
                continue
            }

            service.port = Int(serviceRecord.port)
            service.hostName = serviceRecord.server

            service.addresses = message.additional
                .flatMap { $0 as? HostRecord<IPv4> }
                .filter { $0.name == serviceRecord.server }
                .map { hostRecord in
                    sockaddr_storage.fromSockAddr { (sin: inout sockaddr_in) in
                        sin.sin_family = sa_family_t(AF_INET)
                        sin.sin_addr = hostRecord.ip.address
                        sin.sin_port = serviceRecord.port
                        }.1
            }
            service.addresses! += message.additional
                .flatMap { $0 as? HostRecord<IPv6> }
                .filter { $0.name == serviceRecord.server }
                .map { hostRecord in
                    sockaddr_storage.fromSockAddr { (sin: inout sockaddr_in6) in
                        sin.sin6_family = sa_family_t(AF_INET6)
                        sin.sin6_addr = hostRecord.ip.address
                        sin.sin6_port = serviceRecord.port
                        }.1
            }

            self.services.append(pointer.destination)
            self.delegate?.netServiceBrowser(self, didFind: service, moreComing: false)
        }
    }
}

public protocol NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool)

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool)

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser)
}
