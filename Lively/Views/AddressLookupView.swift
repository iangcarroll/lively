import SwiftUI
import MapKit
import CoreLocation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A written address lookup, independent of conversation and speech settings.
struct AddressLookupView: View {
    @State private var store: AddressLookupStore
    @State private var showsLanguages = false
    @State private var copied = false
    @State private var mapError: String?
    @FocusState private var queryFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(initialLanguage: Language) {
        let saved = UserDefaults.standard.string(forKey: "addressLookupLanguage")
        _store = State(initialValue: AddressLookupStore(
            service: MapAddressLookupService(),
            language: AddressLanguage.matching(saved ?? initialLanguage.locale.identifier)
        ))
    }

    var body: some View {
        @Bindable var lookup = store
        NavigationStack {
            Form {
                Section {
                    TextField("Address or place name", text: $lookup.query, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($queryFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(find)
                        .accessibilityLabel("Address or place name")

                    PasteButton(payloadType: String.self) { values in
                        guard let value = values.first else { return }
                        store.query = value
                        queryFocused = false
                    }
                    .frame(minHeight: 44)

                    Button { showsLanguages = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            if dynamicTypeSize.isAccessibilitySize {
                                Text("Address language").foregroundStyle(.primary)
                                languageValue
                            } else {
                                HStack(spacing: 12) {
                                    Text("Address language").foregroundStyle(.primary)
                                    Spacer()
                                    languageValue
                                }
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Address language, \(store.language.englishName)")

                    Button(action: find) {
                        Label("Find address", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .disabled(!store.canSearch)
                } header: {
                    Text("Location")
                } footer: {
                    Text("Requires internet. Places are looked up with Apple Maps.")
                }

                if store.isBusy {
                    Section {
                        ProgressView(store.phase == .searching ? "Finding places…" : "Finding address…")
                        Button("Cancel lookup", role: .cancel) { store.close() }
                            .frame(minHeight: 44)
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                        Button("Try again") {
                            queryFocused = false
                            store.retry()
                        }
                        .frame(minHeight: 44)
                    }
                }

                if store.phase == .choosing {
                    Section {
                        ForEach(store.matches) { place in
                            Button {
                                queryFocused = false
                                store.select(place)
                            } label: {
                                HStack(spacing: 12) {
                                    placeLabel(place)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(store.matches.count == 1 ? "Confirm the place" : "Choose a place")
                    }
                }

                if store.phase == .resolved, let place = store.selectedPlace, let address = store.address {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            placeLabel(place)
                            Text(address)
                                .font(.title3.weight(.medium))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .environment(\.locale, store.language.locale)
                                .environment(\.layoutDirection, addressDirection)
                        }
                        .padding(.vertical, 4)

                        Button(action: copyAddress) {
                            Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                        }
                        Button { openInMaps(place) } label: {
                            Label("Open in Maps", systemImage: "map")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                        }
                        if let mapError { Text(mapError).foregroundStyle(.red) }
                    } header: {
                        Text("Address in \(store.language.englishName)")
                    } footer: {
                        Text("Names and address details depend on available map data. Some places may keep their local spelling.")
                    }
                }

                if !mapPlaces.isEmpty { locationMap }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(.canvas))
            .navigationTitle("Address")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.close()
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showsLanguages) {
            AddressLanguagePicker(selection: $lookup.language)
        }
        .onChange(of: store.language) { _, language in
            UserDefaults.standard.set(language.code, forKey: "addressLookupLanguage")
        }
        .onChange(of: store.copyValue) { _, _ in
            copied = false
            mapError = nil
        }
        .onDisappear { store.close() }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 640)
        #endif
    }

    private var mapPlaces: [AddressPlace] {
        if store.phase == .choosing { return store.matches }
        if let place = store.selectedPlace { return [place] }
        return []
    }

    private var languageValue: some View {
        HStack(spacing: 12) {
            Text(store.language.nativeName).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }

    private var locationMap: some View {
        Section {
            Map(initialPosition: mapPosition) {
                ForEach(mapPlaces) { place in
                    Marker(place.name, coordinate: coordinate(place))
                }
            }
            .id(mapPlaces.map(\.id))
            .frame(height: 220)
            .listRowInsets(EdgeInsets())
        } header: {
            Text(store.phase == .choosing ? "Locations" : "Selected place")
        }
    }

    private var addressDirection: LayoutDirection {
        store.language.locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    private var mapPosition: MapCameraPosition {
        guard mapPlaces.count == 1, let place = mapPlaces.first else { return .automatic }
        return .region(MKCoordinateRegion(
            center: coordinate(place),
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        ))
    }

    private func placeLabel(_ place: AddressPlace) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(place.name).font(.body.weight(.medium)).foregroundStyle(.primary)
            if !place.subtitle.isEmpty {
                Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func find() {
        queryFocused = false
        store.find()
    }

    private func copyAddress() {
        guard let value = store.copyValue else { return }
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
        copied = true
    }

    private func coordinate(_ place: AddressPlace) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    private func openInMaps(_ place: AddressPlace) {
        let item = MKMapItem(
            location: CLLocation(latitude: place.latitude, longitude: place.longitude),
            address: nil
        )
        item.name = place.name
        if !item.openInMaps() { mapError = "Couldn’t open Maps. Try again." }
    }
}

private struct AddressLanguagePicker: View {
    @Binding var selection: AddressLanguage
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(languages) { language in
                    Button {
                        selection = language
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.nativeName)
                                    .foregroundStyle(.primary)
                                    .environment(\.locale, language.locale)
                                if language.englishName.caseInsensitiveCompare(language.nativeName) != .orderedSame {
                                    Text(language.englishName)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selection == language {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == language ? .isSelected : [])
                }
            }
            .searchable(text: $query, prompt: "Search languages")
            .overlay {
                if languages.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Address Language")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 560)
        #endif
    }

    private var languages: [AddressLanguage] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return AddressLanguage.all }
        return AddressLanguage.all.filter {
            $0.englishName.localizedStandardContains(value)
                || $0.nativeName.localizedStandardContains(value)
                || $0.code.localizedStandardContains(value)
        }
    }
}
