import Foundation
import Vision
import CoreML
import QuartzCore

import SwiftCLI
import Mask_RCNN_CoreML

class EvaluateCommand: Command {
    
    let name = "evaluate"
    let shortDescription = "Evaluates CoreML model against validation data"
    
    let modelName = Parameter()
    let evalDataset = Parameter()
    let configFilePath = Key<String>("--config", description: "Path to config JSON file")
    let weightsFilePath = Key<String>("--weights", description: "Path to HDF5 weights file")
    let productsDirectoryPath = Key<String>("--products_dir", description: "Path to products directory")
    let yearOption = Key<String>("--year", description: "COCO dataset year")
    let typeOption = Key<String>("--type", description: "COCO dataset type")
    let compareFlag = Flag("-c", "--compare")

    func execute() throws {

        guard #available(macOS 10.14, *) else {
            stdout <<< "eval requires macOS >= 10.14"
            return
        }
        
        guard Docker.installed else {
            stdout <<< "Docker is required to run this script."
            return
        }
        
        let name = self.modelName.value
        let evalDataset = self.evalDataset.value
        
        stdout <<< "Evaluating \(name) using \(evalDataset)"
        
        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        let currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
        
        let defaultModelURL = currentDirectoryURL.appendingPathComponent(".maskrcnn/models").appendingPathComponent(name)
        let defaultDataURL = currentDirectoryURL.appendingPathComponent(".maskrcnn/data")
        
        let productsURL:URL = {
            () -> URL in
            guard let productsDirectoryPath = productsDirectoryPath.value else {
                return defaultModelURL.appendingPathComponent("products")
            }
            return URL(fileURLWithPath:productsDirectoryPath, isDirectory:false, relativeTo:currentDirectoryURL).standardizedFileURL
        }()

        let mainModelURL = productsURL.appendingPathComponent("MaskRCNN.mlmodel")
        let classifierModelURL = productsURL.appendingPathComponent("Classifier.mlmodel")
        let maskModelURL = productsURL.appendingPathComponent("Mask.mlmodel")
        let anchorsURL = productsURL.appendingPathComponent("anchors.bin")
        
        let cocoURL = defaultDataURL.appendingPathComponent("coco_eval")
        let annotationsDirectoryURL = cocoURL
        
        let year = yearOption.value ?? "2017"
        let type = typeOption.value ?? "val"
        let imagesDirectoryURL = cocoURL.appendingPathComponent("\(type)\(year)")

        try evaluate(modelURL:mainModelURL,
                     classifierModelURL:classifierModelURL,
                     maskModelURL:maskModelURL,
                     anchorsURL:anchorsURL,
                     annotationsDirectoryURL:annotationsDirectoryURL,
                     imagesDirectoryURL:imagesDirectoryURL,
                     year:year,
                     type:type)
        
        if(compareFlag.value) {
            stdout <<< "Comparison coming soon."
        }
        
    }
}

@available(macOS 10.14, *)
func evaluate(modelURL:URL,
              classifierModelURL:URL,
              maskModelURL:URL,
              anchorsURL:URL,
              annotationsDirectoryURL:URL,
              imagesDirectoryURL:URL,
              year:String,
              type:String) throws {
    
    MaskRCNNConfig.defaultConfig.anchorsURL = anchorsURL
    
    let compiledClassifierUrl = try MLModel.compileModel(at: classifierModelURL)
    MaskRCNNConfig.defaultConfig.compiledClassifierModelURL = compiledClassifierUrl
    
    let compiledMaskUrl = try MLModel.compileModel(at: maskModelURL)
    MaskRCNNConfig.defaultConfig.compiledMaskModelURL = compiledMaskUrl
    
    let compiledUrl = try MLModel.compileModel(at: modelURL)
    let model = try MLModel(contentsOf: compiledUrl)
    
    let vnModel = try VNCoreMLModel(for:model)
    let request = VNCoreMLRequest(model: vnModel)
    request.imageCropAndScaleOption = .scaleFit
    
    let instancesURL = annotationsDirectoryURL.appendingPathComponent("instances_\(type)\(year).json")
    
    let coco = try COCO(url:instancesURL)
    
    var iterator = coco.makeImageIterator(limit:5, sortById:true)
    while let item = iterator.next() {
        let start = Date().timeIntervalSinceReferenceDate
        let image = item.0
        let imageURL = imagesDirectoryURL.appendingPathComponent(image.fileName)
        let ciImage = CIImage(contentsOf:imageURL)!
        let handler = VNImageRequestHandler(ciImage: ciImage)
        try handler.perform([request])
        
        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
            let detectionsFeatureValue = results.first?.featureValue,
            let maskFeatureValue = results.last?.featureValue else {
                return
        }
        let end = Date().timeIntervalSinceReferenceDate
        let detections = Detection.detectionsFromFeatureValue(featureValue: detectionsFeatureValue, maskFeatureValue:maskFeatureValue)
        print(detections.count)
        print(end-start)
    }
}
