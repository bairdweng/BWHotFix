require("UIButton, UIColor","UIViewController");
defineClass("ViewController", {
    viewDidLoad: function() {
        self.super().viewDidLoad();
        var textBtn = UIButton.alloc().initWithFrame({x:30, y:140, width:100, height:100});
        self.view().addSubview(textBtn);
        textBtn.setBackgroundColor(UIColor.blueColor());
        textBtn.addTarget_action_forControlEvents(self, "handleBtn", 1);
        self.view().setBackgroundColor(UIColor.yellowColor());
        self.setShowText("显示文字33333");
    },
    handleBtn: function() {
      console.log("handleBtn handleBtn handleBtn:%@", self.showText());
      var nextVc = TestViewController2.alloc().init();
      self.presentViewController_animated_completion(nextVc, YES, null);
    }
}, {});

// 这个是新的类
defineClass("TestViewController2:UIViewController", {
    viewDidLoad: function() {
        self.super().viewDidLoad();
        self.view().setBackgroundColor(UIColor.redColor());
        
        var textBtn = UIButton.alloc().initWithFrame({x:30, y:140, width:100, height:100});
        self.view().addSubview(textBtn);
        textBtn.setBackgroundColor(UIColor.blueColor());
        textBtn.addTarget_action_forControlEvents(self, "closePage", 1);
        self.view().setBackgroundColor(UIColor.greenColor());
    },
   closePage: function() {
        self.dismissViewControllerAnimated_completion(YES, null);
   }
}, {});




