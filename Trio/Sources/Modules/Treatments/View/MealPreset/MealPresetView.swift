import CoreData
import Foundation
import SwiftUI

/// Root screen of the Presets flow: the meal (cart) the user is assembling.
///
/// The saved presets themselves live in Core Data and are browsed/added from ``FoodPickerView``.
/// On first entry, an empty meal automatically summons the food picker (or, when no presets exist
/// yet, the create-preset sheet). Macros are committed to the treatment via "Add to Treatments".
struct MealPresetView: View {
    @Bindable var state: Treatments.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.managedObjectContext) private var moc
    @Environment(AppState.self) var appState

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) private var carbPresets: FetchedResults<MealPresetStored>

    @State private var didInitialSummon = false
    @State private var showFoodPicker = false
    @State private var showForcedCreate = false
    @State private var tooltipItemID: NSManagedObjectID?

    // Create-preset form, used for the forced "no presets yet" path.
    @State private var newDish = ""
    @State private var newCarbs: Decimal = 0
    @State private var newFat: Decimal = 0
    @State private var newProtein: Decimal = 0

    private var mealFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.mealPresetItems.isEmpty {
                    emptyMeal
                } else {
                    mealList
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Meal")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFoodPicker = true
                    } label: {
                        HStack {
                            Text("Add Food")
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !state.mealPresetItems.isEmpty {
                    bottomBar
                }
            }
            .sheet(isPresented: $showFoodPicker) {
                FoodPickerView(state: state)
                    .environment(\.managedObjectContext, moc)
            }
            .sheet(isPresented: $showForcedCreate) {
                AddMealPresetView(
                    dish: $newDish,
                    presetCarbs: $newCarbs,
                    presetFat: $newFat,
                    presetProtein: $newProtein,
                    displayFatAndProtein: $state.useFPUconversion,
                    onSave: {
                        if let preset = state.createPreset(
                            dish: newDish,
                            carbs: newCarbs,
                            fat: newFat,
                            protein: newProtein
                        ) {
                            state.addPresetToMeal(preset)
                        }
                        resetCreateForm()
                        showForcedCreate = false
                    },
                    onCancel: {
                        // Backing out of the forced create step leaves the whole Presets feature.
                        resetCreateForm()
                        dismiss()
                    }
                )
            }
            .onAppear(perform: summonInitialScreenIfNeeded)
            .onDisappear {
                state.resetMeal()
            }
        }
    }

    // MARK: - Meal (empty)

    private var emptyMeal: some View {
        ContentUnavailableView {
            Label("No Foods in Meal", systemImage: "fork.knife")
        } description: {
            Text("Add foods from your saved presets to build this meal.")
        } actions: {
            Button {
                showFoodPicker = true
            } label: {
                Text("Add Food")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Meal (with items)

    private var mealList: some View {
        Form {
            Section(header: Text("This Meal")) {
                ForEach(state.mealPresetItems) { item in
                    mealRow(item)
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    private func mealRow(_ item: MealPresetItem) -> some View {
        HStack {
            Text(item.preset.dish ?? "")
            Spacer()
            HStack(spacing: 16) {
                Button {
                    minusTapped(item)
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title3)
                }
                .tint(.blue)
                .popover(isPresented: tooltipBinding(for: item), arrowEdge: .bottom) {
                    Button(role: .destructive) {
                        tooltipItemID = nil
                        state.removeMealItem(item)
                    } label: {
                        Label("Delete from meal", systemImage: "trash")
                    }
                    .padding()
                    .presentationCompactAdaptation(.popover)
                }

                Text("\(item.quantity)")
                    .font(.headline)
                    .frame(minWidth: 24)

                Button {
                    state.incrementMealItem(item)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .tint(.blue)
            }
            .buttonStyle(.borderless)
        }
    }

    private func minusTapped(_ item: MealPresetItem) {
        if item.quantity > 1 {
            state.decrementMealItem(item)
        } else {
            // At quantity 1, surface a confirmation tooltip instead of silently removing the item.
            tooltipItemID = item.id
        }
    }

    private func tooltipBinding(for item: MealPresetItem) -> Binding<Bool> {
        Binding(
            get: { tooltipItemID == item.id },
            set: { isShown in if !isShown { tooltipItemID = nil } }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                macroLabel("Carbs", value: state.mealCarbs)
                if state.useFPUconversion {
                    macroLabel("Protein", value: state.mealProtein)
                    macroLabel("Fat", value: state.mealFat)
                }
                Spacer()
            }
            .font(.footnote)

            Button {
                state.commitMealToTreatments()
                dismiss()
            } label: {
                Text("Add to Treatments")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(.bar)
    }

    private func macroLabel(_ title: LocalizedStringKey, value: Decimal) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value as NSNumber, formatter: mealFormatter) g")
        }
    }

    // MARK: - Helpers

    private func summonInitialScreenIfNeeded() {
        guard !didInitialSummon else { return }
        didInitialSummon = true
        guard state.mealPresetItems.isEmpty else { return }
        if carbPresets.isEmpty {
            showForcedCreate = true
        } else {
            showFoodPicker = true
        }
    }

    private func resetCreateForm() {
        newDish = ""
        newCarbs = 0
        newFat = 0
        newProtein = 0
    }
}

/// Inner sheet listing the saved meal presets. Tapping a food adds it to the meal and dismisses;
/// "Select Multiple" enables batch-adding; "Edit Presets" enables permanent deletion of saved presets.
struct FoodPickerView: View {
    enum Mode {
        case normal
        case multiAdd
        case editPresets
    }

    @Bindable var state: Treatments.StateModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) private var carbPresets: FetchedResults<MealPresetStored>

    @State private var mode: Mode = .normal
    @State private var selectedForAdd: Set<NSManagedObjectID> = []
    @State private var showCreate = false
    @State private var presetPendingDelete: MealPresetStored?
    @State private var showDeleteInMealAlert = false

    // Create-preset form.
    @State private var newDish = ""
    @State private var newCarbs: Decimal = 0
    @State private var newFat: Decimal = 0
    @State private var newProtein: Decimal = 0

    private var mealFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    var body: some View {
        NavigationStack {
            Group {
                if carbPresets.isEmpty {
                    emptyLibrary
                } else {
                    presetList
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(mode == .editPresets ? .active : .inactive))
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if mode == .multiAdd {
                    addSelectedBar
                }
            }
            .alert(
                "Delete preset?",
                isPresented: $showDeleteInMealAlert,
                presenting: presetPendingDelete
            ) { preset in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { state.deletePreset(preset) }
            } message: { preset in
                Text(
                    "'\(preset.dish ?? "")' is in your current meal. Deleting the preset will also remove it from the meal."
                )
            }
            .sheet(isPresented: $showCreate) {
                AddMealPresetView(
                    dish: $newDish,
                    presetCarbs: $newCarbs,
                    presetFat: $newFat,
                    presetProtein: $newProtein,
                    displayFatAndProtein: $state.useFPUconversion,
                    onSave: {
                        state.createPreset(dish: newDish, carbs: newCarbs, fat: newFat, protein: newProtein)
                        resetCreateForm()
                        showCreate = false
                    },
                    onCancel: {
                        resetCreateForm()
                        showCreate = false
                    }
                )
            }
            .onChange(of: carbPresets.isEmpty) { _, isEmpty in
                if isEmpty {
                    mode = .normal
                    selectedForAdd.removeAll()
                }
            }
        }
    }

    private var navTitle: String {
        switch mode {
        case .normal: return String(localized: "Foods")
        case .multiAdd: return String(localized: "Select Foods")
        case .editPresets: return String(localized: "Edit Presets")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            switch mode {
            case .normal:
                Button("Cancel") { dismiss() }
            case .multiAdd:
                Button("Cancel") {
                    mode = .normal
                    selectedForAdd.removeAll()
                }
            case .editPresets:
                Button("Done") { mode = .normal }
            }
        }
        if mode == .normal, !carbPresets.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        mode = .multiAdd
                    } label: {
                        Label("Select Multiple", systemImage: "checkmark.circle")
                    }
                    Button {
                        mode = .editPresets
                    } label: {
                        Label("Edit Presets", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Library (empty)

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Saved Foods", systemImage: "tray")
        } description: {
            Text("Create a preset to start adding foods to your meal.")
        } actions: {
            Button {
                showCreate = true
            } label: {
                Text("Add New Preset")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Library (with presets)

    private var presetList: some View {
        Form {
            Section {
                ForEach(carbPresets) { preset in
                    presetRow(preset)
                }
                .onDelete(perform: deleteRows)
            }
            .listRowBackground(Color.chart)

            if mode == .normal {
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("Add New Preset", systemImage: "plus")
                    }
                }
                .listRowBackground(Color.chart)
            }
        }
    }

    private func presetRow(_ preset: MealPresetStored) -> some View {
        Button {
            rowTapped(preset)
        } label: {
            HStack {
                if mode == .multiAdd {
                    Image(systemName: selectedForAdd.contains(preset.objectID) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedForAdd.contains(preset.objectID) ? Color.accentColor : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.dish ?? "")
                        .foregroundStyle(.primary)
                    Text(macroSummary(preset))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .normal {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowTapped(_ preset: MealPresetStored) {
        switch mode {
        case .normal:
            state.addPresetToMeal(preset)
            dismiss()
        case .multiAdd:
            if selectedForAdd.contains(preset.objectID) {
                selectedForAdd.remove(preset.objectID)
            } else {
                selectedForAdd.insert(preset.objectID)
            }
        case .editPresets:
            break
        }
    }

    private func deleteRows(_ offsets: IndexSet) {
        for index in offsets {
            let preset = carbPresets[index]
            if state.mealContains(preset) {
                // Deleting a preset that is part of the meal needs explicit confirmation.
                presetPendingDelete = preset
                showDeleteInMealAlert = true
            } else {
                state.deletePreset(preset)
            }
        }
    }

    // MARK: - Multi-select bar

    private var addSelectedBar: some View {
        Button {
            addSelectedToMeal()
        } label: {
            Text(selectedForAdd.isEmpty ? "Select Foods to Add" : "Add \(selectedForAdd.count) to Meal")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selectedForAdd.isEmpty)
        .padding()
        .background(.bar)
    }

    private func addSelectedToMeal() {
        for preset in carbPresets where selectedForAdd.contains(preset.objectID) {
            state.addPresetToMeal(preset)
        }
        dismiss()
    }

    // MARK: - Helpers

    private func macroSummary(_ preset: MealPresetStored) -> String {
        let carbs = decimalString(preset.carbs)
        if state.useFPUconversion {
            let protein = decimalString(preset.protein)
            let fat = decimalString(preset.fat)
            return String(localized: "\(carbs) g carbs · \(protein) g protein · \(fat) g fat")
        }
        return String(localized: "\(carbs) g carbs")
    }

    private func decimalString(_ value: NSDecimalNumber?) -> String {
        let number = (value ?? 0) as NSNumber
        return mealFormatter.string(from: number) ?? "0"
    }

    private func resetCreateForm() {
        newDish = ""
        newCarbs = 0
        newFat = 0
        newProtein = 0
    }
}
