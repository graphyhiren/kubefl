import { ConfigVolume, Config } from "src/app/utils/types";
import { Validators, FormBuilder, FormGroup, FormArray } from "@angular/forms";

const fb = new FormBuilder();

export function getFormDefaults(): FormGroup {
  return fb.group({
    name: ["", [Validators.required]],
    namespace: ["", [Validators.required]],
    image: ["", [Validators.required]],
    customImage: ["", []],
    customImageCheck: [false, []],
    cpu: ["", [Validators.required]],
    memory: ["", [Validators.required]],
    noWorkspace: [false, []],
    workspace: fb.group({
      type: ["", [Validators.required]],
      name: ["", [Validators.required]],
      size: ["", [Validators.required]],
      path: [{ value: "", disabled: true }, [Validators.required]],
      mode: ["", [Validators.required]],
      class: ["", [Validators.required]],
      extraFields: fb.group({})
    }),
    datavols: fb.array([]),
    extra: ["", [Validators.required]]
  });
}

export function createVolumeControl(vol: ConfigVolume) {
  const ctrl = fb.group({
    type: [vol.type.value, [Validators.required]],
    name: [vol.name.value, [Validators.required]],
    size: [vol.size.value, [Validators.required]],
    path: [vol.mountPath.value, [Validators.required]],
    mode: [vol.accessModes.value, [Validators.required]],
    class: ["{none}", []],
    extraFields: fb.group({})
  });

  return ctrl;
}

export function addDataVolume(formCtrl: FormGroup, vol: ConfigVolume = null) {
  // If no vol is provided create one with default values
  if (vol === null) {
    const l: number = formCtrl.value.datavols.length;

    vol = {
      type: {
        value: "New"
      },
      name: {
        value: "{notebook-name}-vol-" + (l + 1)
      },
      size: {
        value: "10Gi"
      },
      mountPath: {
        value: "/home/jovyan/data-vol-" + (l + 1)
      },
      accessModes: {
        value: "ReadWriteOnce"
      }
    };
  }

  // Push it to the control
  const vols = formCtrl.get("datavols") as FormArray;
  vols.push(createVolumeControl(vol));
}

export function initFormControls(formCtrl: FormGroup, config: Config) {
  // Sets the values from our internal dict. This is an initialization step
  // that should be only run once
  formCtrl.controls.cpu.setValue(config.cpu.value);
  formCtrl.controls.memory.setValue(config.memory.value);
  formCtrl.controls.image.setValue(config.image.value);

  formCtrl.controls.workspace = createVolumeControl(
    config.workspaceVolume.value
  );

  // Disable the mount path by default
  const ws = formCtrl.controls.workspace as FormGroup;
  ws.controls.path.disable();

  // Add the data volumes
  const arr = fb.array([]);
  config.dataVolumes.value.forEach(vol => {
    // Create a new FormControl to append to the array
    arr.push(createVolumeControl(vol.value));
  });
  formCtrl.controls.datavols = arr;

  formCtrl.controls.extra.setValue(config.extraResources.value);
}
