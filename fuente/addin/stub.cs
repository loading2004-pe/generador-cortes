using System; using System.Collections; using System.Collections.Generic;
namespace Autodesk.Revit.Attributes { public enum TransactionMode { ReadOnly, Manual } public class TransactionAttribute : Attribute { public TransactionAttribute(TransactionMode m) {} } }
namespace Autodesk.Revit.DB {
 public class ElementId { public static ElementId InvalidElementId; public ElementId(BuiltInCategory c) {} public override string ToString() { return "1"; } public static bool operator ==(ElementId a, ElementId b) { return true; } public static bool operator !=(ElementId a, ElementId b) { return false; } public override bool Equals(object o) { return true; } public override int GetHashCode() { return 0; } }
 public enum BuiltInCategory { OST_PointClouds }
 public class Category { public ElementId Id; }
 public class Categories : IEnumerable { public IEnumerator GetEnumerator() { return new List<Category>().GetEnumerator(); } }
 public class Settings { public Categories Categories; }
 public class TransactionGroup : IDisposable { public TransactionGroup(Document d, string n) {} public void Start() {} public void RollBack() {} public void Dispose() {} }
 public enum ExportRange { SetOfViews } public enum ImageFileType { BMP } public enum ZoomFitType { FitToPage } public enum FitDirectionType { Horizontal } public enum ImageResolution { DPI_600 }
 public class ImageExportOptions { public ExportRange ExportRange; public string FilePath; public ImageFileType HLRandWFViewsFileType, ShadowViewsFileType; public ZoomFitType ZoomType; public FitDirectionType FitDirection; public int PixelSize; public ImageResolution ImageResolution; public void SetViewsAndSheets(IList<ElementId> l) {} }
 public class Element { public ElementId Id; public string Name; public Parameter get_Parameter(BuiltInParameter p) { return null; } }
 public class Parameter { public bool HasValue, IsReadOnly; public double AsDouble() { return 0; } public bool Set(int v) { return true; } public bool Set(double v) { return true; } }
 public enum BuiltInParameter { VIEWER_BOUND_OFFSET_FAR, VIEWER_BOUND_FAR_CLIPPING, VIEWER_ANNOTATION_CROP_ACTIVE }
 public enum ViewType { Section }
 public class XYZ { public static XYZ BasisX; public double X, Y, Z; public XYZ(double a, double b, double c) {} public XYZ Negate() { return this; } public XYZ Normalize() { return this; } public static XYZ operator -(XYZ a, XYZ b) { return a; } public double GetLength() { return 1; } }
 public class Transform { public static Transform Identity; public Transform Inverse; public XYZ BasisZ; public XYZ OfPoint(XYZ p) { return p; } public XYZ OfVector(XYZ p) { return p; } }
 public class BoundingBoxXYZ { public Transform Transform; public XYZ Min, Max; }
 public class View : Element { public bool IsTemplate, CropBoxActive, CropBoxVisible, AreAnnotationCategoriesHidden; public ViewType ViewType; public BoundingBoxXYZ CropBox; public ElementId ViewTemplateId; public bool CanCategoryBeHidden(ElementId i) { return true; } public void SetCategoryHidden(ElementId i, bool h) {} }
 public class ViewSection : View {}
 public class Plane { public static Plane CreateByNormalAndOrigin(XYZ n, XYZ o) { return null; } }
 public class PointCloudInstance : Element { public Autodesk.Revit.DB.PointClouds.PointCollection GetPoints(Autodesk.Revit.DB.PointClouds.PointCloudFilter f, double a, int n) { return null; } public Transform GetTransform() { return null; } public static PointCloudInstance Create(Document d, ElementId t, Transform tr) { return null; } }
 public class PointCloudType : Element { public static PointCloudType Create(Document d, string e, string n) { return null; } }
 public class Document { public string Title; public bool IsFamilyDocument; public Settings Settings; public bool ExportImage(ImageExportOptions o) { return true; } }
 public class FilteredElementCollector : IEnumerable { public FilteredElementCollector(Document d) {} public FilteredElementCollector OfClass(Type t) { return this; } public IEnumerator GetEnumerator() { return new List<Element>().GetEnumerator(); } }
 public class Transaction : IDisposable { public Transaction(Document d, string n) {} public void Start() {} public void Commit() {} public void Dispose() {} }
 public class ElementSet {}
}
namespace Autodesk.Revit.DB.Events { public class DocumentChangedEventArgs : EventArgs {} public class DocumentOpenedEventArgs : EventArgs {} }
namespace Autodesk.Revit.ApplicationServices { public class ControlledApplication { public event EventHandler<Autodesk.Revit.DB.Events.DocumentChangedEventArgs> DocumentChanged; public event EventHandler<Autodesk.Revit.DB.Events.DocumentOpenedEventArgs> DocumentOpened; } }
namespace Autodesk.Revit.UI.Events { public class IdlingEventArgs : EventArgs {} public class ViewActivatedEventArgs : EventArgs {} }
namespace Autodesk.Revit.UI {
 public enum Result { Succeeded, Failed }
 public interface IExternalApplication { Result OnStartup(UIControlledApplication a); Result OnShutdown(UIControlledApplication a); }
 public interface IExternalCommand { Result Execute(ExternalCommandData d, ref string m, Autodesk.Revit.DB.ElementSet e); }
 public interface IExternalEventHandler { void Execute(UIApplication a); string GetName(); }
 public class ExternalEvent { public static ExternalEvent Create(IExternalEventHandler h) { return null; } public int Raise() { return 0; } }
 public class UIControlledApplication { public IntPtr MainWindowHandle; public Autodesk.Revit.ApplicationServices.ControlledApplication ControlledApplication; public event EventHandler<Autodesk.Revit.UI.Events.ViewActivatedEventArgs> ViewActivated; public event EventHandler<Autodesk.Revit.UI.Events.IdlingEventArgs> Idling; public RibbonPanel CreateRibbonPanel(string n) { return null; } }
 public class RibbonPanel { public object AddItem(PushButtonData d) { return null; } }
 public class PushButtonData { public string ToolTip; public PushButtonData(string a, string b, string c, string d) {} }
 public class UIDocument { public Autodesk.Revit.DB.Document Document; }
 public class UIApplication { public UIDocument ActiveUIDocument; }
 public class ExternalCommandData { public UIApplication Application; }
 public static class TaskDialog { public static void Show(string a, string b) {} }
}

namespace Autodesk.Revit.DB.PointClouds { using Autodesk.Revit.DB;
 public class PointCloudFilter {}
 public static class PointCloudFilterFactory { public static PointCloudFilter CreateMultiPlaneFilter(IList<Plane> p) { return null; } }
 public struct CloudPoint { public float X, Y, Z; public int Color; }
 public class PointCollection : IEnumerable<CloudPoint> { public int Count; public IEnumerator<CloudPoint> GetEnumerator() { return null; } IEnumerator IEnumerable.GetEnumerator() { return null; } }
}
